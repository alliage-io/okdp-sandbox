#!/usr/bin/env bash
#
# Copyright 2026 The OKDP Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.
#

# End-to-end test of one GitOps engine on a throwaway kind cluster, the way the
# README installs the sandbox: kind cluster nokubocd-<engine> (own kubeconfig, the
# current context is never used), Forgejo bootstrapped with helm from the 20-forgejo
# component (then adopted by the engine), the layout pushed to
# http://forgejo-http.forgejo.svc.cluster.local:3000/okdp/okdp-sandbox.git (branch main),
# the engine, its entry point, then a wait until every release is ready.
#
# What is pushed is a copy of the layout at E2E_REF, adapted for the test:
#   - the control plane server's gitops.engine is set to the engine under test;
#   - E2E_CHART_MAP rewrites chart references (unpublished charts in a local
#     registry) in every instance.yaml, in the catalog and in the chart registries
#     the project AppProjects allow;
#   - E2E_SERVER_IMAGE and E2E_UI_IMAGE (repository:tag) replace the images of the
#     control plane (load them with E2E_LOAD_IMAGES);
#   - then the copy is compiled (okdp-gitops compile, the charts of E2E_CHARTS first);
#   - E2E_PLAIN_HTTP_REGISTRY (host:port) is reached over plain HTTP: Flux
#     OCIRepositories get spec.insecure (Kustomization patches), Argo CD gets one
#     repository Secret per chart repository (insecureOCIForceHttp), the server
#     gets insecureOciRegistries;
#   - E2E_SKIP_PROJECTS=1 drops projects/ (platform only).
#
# Usage:
#   e2e-kind.sh up   <flux|argocd>   create, deploy and wait
#   e2e-kind.sh push <flux|argocd>   push E2E_REF again (adapted) to the cluster's Forgejo
#   e2e-kind.sh down <flux|argocd>   delete the cluster
# Environment:
#   E2E_DIR       work directory (kubeconfigs, pushed copy), default ./.e2e
#   E2E_REF       Git ref of this repository to deploy, default HEAD (commit first)
#   E2E_CHART_MAP "FROM=TO" chart reference prefix rewrite, e.g.
# TODO(no-kubocd): temporary registry, revert to quay.io/okdp once the OKDP charts are published there.
#                 oci://repo.alliage.io:8082/okdp=oci://nokubocd-registry:5000/okdp
#   E2E_PLAIN_HTTP_REGISTRY  e.g. nokubocd-registry:5000
#   E2E_REGISTRY_CONTAINER   Docker container of that registry, connected to the kind network
#   E2E_CHARTS    directory of packaged charts (<chart>-<version>.tgz: package-charts.sh of
#                 the chart repositories, or pull-charts.sh): the compile reads them first
#   E2E_REGISTRY_HOST  E2E_PLAIN_HTTP_REGISTRY as the host reaches it (e.g. 127.0.0.1:5001):
#                 the chart of every instance mapped to E2E_PLAIN_HTTP_REGISTRY is pushed
#                 there from E2E_CHARTS (plain HTTP), at its path, before the deployment
#   E2E_SERVER_IMAGE, E2E_UI_IMAGE   images of the control plane (repository:tag)
#   OKDP_GITOPS   the okdp-gitops binary (default: okdp-gitops in PATH)
#   E2E_LOAD_IMAGES          images loaded into the kind node (space separated)
#   E2E_SKIP_PROJECTS        1: platform components only
#   FLUX_VERSION  default v2.9.5          ARGOCD_VERSION  default v3.4.2
#   E2E_TIMEOUT   seconds, default 2400
# Afterwards: KUBECONFIG=$E2E_DIR/<engine>.kubeconfig kubectl ...

set -euo pipefail

ACTION="${1:-}"; ENGINE="${2:-}"
[[ "$ACTION" =~ ^(up|push|down)$ && "$ENGINE" =~ ^(flux|argocd)$ ]] || { sed -n '18,62p' "$0"; exit 2; }

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPTS/.." && pwd)"
PREFIX="$(git -C "$ROOT" rev-parse --show-prefix)"; PREFIX="${PREFIX%/}"
E2E_DIR="$(mkdir -p "${E2E_DIR:-./.e2e}" && cd "${E2E_DIR:-./.e2e}" && pwd)"
E2E_REF="${E2E_REF:-HEAD}"
E2E_CHART_MAP="${E2E_CHART_MAP:-}"
E2E_PLAIN_HTTP_REGISTRY="${E2E_PLAIN_HTTP_REGISTRY:-}"
E2E_REGISTRY_CONTAINER="${E2E_REGISTRY_CONTAINER:-}"
E2E_LOAD_IMAGES="${E2E_LOAD_IMAGES:-}"
E2E_SKIP_PROJECTS="${E2E_SKIP_PROJECTS:-}"
E2E_CHARTS="${E2E_CHARTS:-}"
E2E_REGISTRY_HOST="${E2E_REGISTRY_HOST:-}"
E2E_SERVER_IMAGE="${E2E_SERVER_IMAGE:-}"
E2E_UI_IMAGE="${E2E_UI_IMAGE:-}"
OKDP_GITOPS="${OKDP_GITOPS:-okdp-gitops}"
FLUX_VERSION="${FLUX_VERSION:-v2.9.5}"
ARGOCD_VERSION="${ARGOCD_VERSION:-v3.4.2}"
E2E_TIMEOUT="${E2E_TIMEOUT:-2400}"
CLUSTER="nokubocd-$ENGINE"
export KUBECONFIG="$E2E_DIR/$ENGINE.kubeconfig"
COPY="$E2E_DIR/$ENGINE-repo"

log() { echo "[$CLUSTER] $*"; }

if [[ "$ACTION" == down ]]; then
  kind delete cluster --name "$CLUSTER" --kubeconfig "$KUBECONFIG"
  rm -rf "$KUBECONFIG" "$COPY"
  exit 0
fi

# ---------------------------------------------------------- adapted copy
# prepare_copy: $COPY = the repository at E2E_REF with the test adaptations,
# committed on top of E2E_REF (a fresh history each time: pushes are forced).
prepare_copy() {
  rm -rf "$COPY"; mkdir -p "$COPY"
  git -C "$(git -C "$ROOT" rev-parse --show-toplevel)" archive "$E2E_REF" | tar -x -C "$COPY"
  local g="$COPY/$PREFIX" f
  [[ -z "$E2E_SKIP_PROJECTS" ]] || rm -rf "$g/projects"/*
  ENGINE="$ENGINE" yq -i '.gitops.engine = strenv(ENGINE)' "$g/platform/components/30-okdp-control-plane-server/values.yaml"
  if [[ -n "$E2E_CHART_MAP" ]]; then
    local from="${E2E_CHART_MAP%%=*}" to="${E2E_CHART_MAP#*=}"
    while IFS= read -r f; do
      FROM="$from" TO="$to" yq -i '.chart |= sub("^" + strenv(FROM); strenv(TO))' "$f"
    done < <(find "$g" -name instance.yaml -not -path "$g/optional/*")
    FROM="$from" TO="$to" yq -i '.defaultRepository |= sub("^" + strenv(FROM); strenv(TO))' "$g/platform/catalog.yaml"
    # The chart registries the project AppProjects allow (Argo CD patterns, no oci://).
    FROM="${from#oci://}" TO="${to#oci://}" yq -i '.chartRepositories |= sub("^" + strenv(FROM); strenv(TO))' "$g/argocd/okdp-project/values.yaml"
  fi
  if [[ -n "$E2E_PLAIN_HTTP_REGISTRY" ]]; then
    REG="$E2E_PLAIN_HTTP_REGISTRY" yq -i '.insecureOciRegistries = strenv(REG)' "$g/platform/components/30-okdp-control-plane-server/values.yaml"
  fi
  local c image
  for c in server ui; do
    image="E2E_${c^^}_IMAGE"; image="${!image}"
    [[ -n "$image" ]] || continue
    REPO="${image%:*}" TAG="${image##*:}" yq -i '.imageRepository = strenv(REPO) | .imageTag = strenv(TAG)' \
      "$g/platform/components/30-okdp-control-plane-$c/values.yaml"
  done
  local charts=()
  [[ -z "$E2E_CHARTS" ]] || charts=(--charts "$E2E_CHARTS")
  "$OKDP_GITOPS" compile --root "$g" --path-prefix "$PREFIX" "${charts[@]}" >/dev/null
  if [[ -n "$E2E_PLAIN_HTTP_REGISTRY" ]]; then
    # Flux: every OCIRepository of the components and projects is plain HTTP.
    # shellcheck disable=SC2016
    local patch='[{"target": {"kind": "OCIRepository"}, "patch": "- op: add\n  path: /spec/insecure\n  value: true\n"}]'
    PATCH="$patch" yq -i '(select(.kind == "Kustomization") | .spec.patches) = env(PATCH)' "$g/flux/components.yaml"
  fi
  git -C "$COPY" init -q -b main
  git -C "$COPY" add -A
  git -C "$COPY" -c user.name=e2e -c user.email=e2e@okdp.io commit -q -m "e2e: $(git -C "$ROOT" rev-parse --short "$E2E_REF") adapted for $ENGINE"
}

FORGEJO_USER="$(yq '.gitea.admin.username' "$ROOT/platform/components/20-forgejo/values.yaml")"
FORGEJO_PASSWORD="$(yq '.gitea.admin.password' "$ROOT/platform/components/20-forgejo/values.yaml")"

push_copy() {
  log "pushing $E2E_REF (adapted) to okdp/okdp-sandbox main"
  kubectl -n forgejo port-forward svc/forgejo-http 0:3000 >"$E2E_DIR/$ENGINE.pf.log" 2>&1 &
  local pf=$! port=""
  for _ in $(seq 30); do
    port="$(sed -n 's/.*127.0.0.1:\([0-9]*\) ->.*/\1/p' "$E2E_DIR/$ENGINE.pf.log" | head -n 1)"
    [[ -n "$port" ]] && break
    sleep 1
  done
  [[ -n "$port" ]] || { log "port-forward failed"; cat "$E2E_DIR/$ENGINE.pf.log"; kill $pf; exit 1; }
  # The credentials go through GIT_ASKPASS (environment, not the command line: a
  # password in the URL shows in ps); no credential helper stores them.
  local askpass
  askpass="$(mktemp -d)"
  cat >"$askpass/askpass.sh" <<'ASKPASS'
#!/bin/sh
case "$1" in
  Username*) printf '%s\n' "$E2E_GIT_USER" ;;
  *) printf '%s\n' "$E2E_GIT_PASSWORD" ;;
esac
ASKPASS
  chmod 700 "$askpass/askpass.sh"
  local rc=0
  GIT_ASKPASS="$askpass/askpass.sh" GIT_TERMINAL_PROMPT=0 \
    E2E_GIT_USER="$FORGEJO_USER" E2E_GIT_PASSWORD="$FORGEJO_PASSWORD" \
    git -C "$COPY" -c credential.helper= push -q --force "http://127.0.0.1:$port/okdp/okdp-sandbox.git" main || rc=$?
  rm -rf "$askpass"
  kill $pf 2>/dev/null || true
  return "$rc"
}

if [[ "$ACTION" == push ]]; then
  prepare_copy; push_copy; exit 0
fi

# ------------------------------------------------------------------ cluster
if kind get clusters | grep -qx "$CLUSTER"; then
  log "cluster exists"
  kind export kubeconfig --name "$CLUSTER" --kubeconfig "$KUBECONFIG"
else
  # TODO(no-kubocd): temporary registry, revert to quay.io/okdp once the OKDP images are published there.
  # (the containerd registry config_path, for the plain HTTP repo.alliage.io:8082 below)
  kind create cluster --name "$CLUSTER" --kubeconfig "$KUBECONFIG" --wait 120s --config - <<'KIND'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
containerdConfigPatches:
- |-
  [plugins."io.containerd.grpc.v1.cri".registry]
    config_path = "/etc/containerd/certs.d"
KIND
fi
# TODO(no-kubocd): temporary registry, revert to quay.io/okdp once the OKDP images are published there.
# The control plane images come from repo.alliage.io:8082, over plain HTTP.
docker exec "$CLUSTER-control-plane" mkdir -p /etc/containerd/certs.d/repo.alliage.io:8082
docker exec -i "$CLUSTER-control-plane" tee /etc/containerd/certs.d/repo.alliage.io:8082/hosts.toml >/dev/null <<'HOSTS'
server = "http://repo.alliage.io:8082"
[host."http://repo.alliage.io:8082"]
  capabilities = ["pull", "resolve"]
HOSTS
[[ "$(kubectl config current-context)" == "kind-$CLUSTER" ]] || { log "unexpected context"; exit 1; }
if [[ -n "$E2E_REGISTRY_CONTAINER" ]]; then
  docker network connect kind "$E2E_REGISTRY_CONTAINER" 2>/dev/null || true
fi
for image in $E2E_LOAD_IMAGES; do
  kind load docker-image "$image" --name "$CLUSTER"
done


prepare_copy

# The charts the copy takes from the local registry, from E2E_CHARTS.
if [[ -n "$E2E_REGISTRY_HOST" && -n "$E2E_PLAIN_HTTP_REGISTRY" && -n "$E2E_CHARTS" ]]; then
  log "pushing the charts of $E2E_CHARTS to $E2E_REGISTRY_HOST"
  while IFS=$'\t' read -r chart version; do
    path="${chart#"oci://$E2E_PLAIN_HTTP_REGISTRY"/}"
    [[ "$path" != "$chart" ]] || continue
    tgz="$E2E_CHARTS/${chart##*/}-$version.tgz"
    [[ -f "$tgz" ]] || { log "$tgz is missing"; exit 1; }
    helm push "$tgz" "oci://$E2E_REGISTRY_HOST/${path%/*}" --plain-http >/dev/null 2>"$E2E_DIR/push.log" \
      || { log "helm push $tgz failed"; cat "$E2E_DIR/push.log"; exit 1; }
  done < <(find "$COPY/$PREFIX/platform/components" "$COPY/$PREFIX/projects" -name instance.yaml \
    | xargs -r yq -r '.chart + "\t" + .version' | sort -u)
fi

# -------------------------------------------------------------------- forgejo
# Bootstrap: the same release the engine manages afterwards (forgejo-forgejo in forgejo),
# with the component's compiled values.
g="$COPY/$PREFIX/platform/components/20-forgejo"
log "installing Forgejo (bootstrap of the 20-forgejo component)"
helm upgrade --install "$(yq '.project + "-" + .name' "$g/instance.yaml")" "$(yq '.chart' "$g/instance.yaml")" \
  --version "$(yq '.version' "$g/instance.yaml")" -n "$(yq '.project' "$g/instance.yaml")" --create-namespace \
  -f "$COPY/$PREFIX/compiled/platform/components/20-forgejo/values.yaml" --wait --timeout 10m
push_copy

# ------------------------------------------------------------------- engine
wait_for() {  # wait_for DESCRIPTION COMMAND...: retry until COMMAND succeeds
  local what="$1"; shift
  local deadline=$((SECONDS + E2E_TIMEOUT))
  until "$@"; do
    (( SECONDS < deadline )) || { log "timeout waiting for $what"; return 1; }
    sleep 20
  done
  log "$what: ok"
}

expected="$(find "$COPY/$PREFIX/projects" "$COPY/$PREFIX/platform/components" -name instance.yaml | wc -l)"

if [[ "$ENGINE" == flux ]]; then
  log "installing Flux $FLUX_VERSION"
  flux install --version="$FLUX_VERSION" --components=source-controller,kustomize-controller,helm-controller
  # Chart version without the OCI digest (see gitops/README.md, "Install with Flux").
  kubectl -n flux-system patch deployment helm-controller --type json \
    -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--feature-gates=DisableChartDigestTracking=true"}]'
  kubectl -n flux-system rollout status deployment helm-controller --timeout=5m
  kubectl apply -f "$COPY/$PREFIX/flux/sync.yaml"
  flux_ready() {
    local n
    n="$(kubectl get helmreleases.helm.toolkit.fluxcd.io -n okdp-releases -o json 2>/dev/null \
      | jq '[.items[] | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))] | length')"
    log "HelmReleases ready: ${n:-0}/$expected"
    [[ "${n:-0}" == "$expected" ]]
  }
  wait_for "HelmReleases ready" flux_ready
  flux get kustomizations
  flux get helmreleases -n okdp-releases
else
  log "installing Argo CD $ARGOCD_VERSION"
  kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
  kubectl apply -n argocd --server-side --force-conflicts \
    -f "https://raw.githubusercontent.com/argoproj/argo-cd/$ARGOCD_VERSION/manifests/install.yaml"
  kubectl -n argocd patch configmap argocd-cmd-params-cm --type merge \
    -p '{"data":{"applicationsetcontroller.enable.progressive.syncs":"true"}}'
  kubectl -n argocd rollout restart deployment argocd-applicationset-controller
  kubectl -n argocd rollout status deployment --timeout=10m
  kubectl -n argocd rollout status statefulset --timeout=10m
  if [[ -n "$E2E_PLAIN_HTTP_REGISTRY" ]]; then
    # One repository Secret per chart repository of the registry (plain HTTP OCI).
    while IFS= read -r repo; do
      name="e2e-$(echo "$repo" | tr -c 'a-z0-9\n' '-')"
      kubectl -n argocd apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${name:0:63}
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: helm
  name: ${name:0:63}
  url: $repo
  enableOCI: "true"
  insecureOCIForceHttp: "true"
EOF
    done < <(find "$COPY/$PREFIX" -name instance.yaml -not -path "*/optional/*" -exec yq '.chart' {} \; \
      | sed -n "s|^oci://\($E2E_PLAIN_HTTP_REGISTRY/.*\)/[^/]*$|\1|p" | sort -u)
  fi
  kubectl apply -n argocd -f "$COPY/$PREFIX/argocd/"
  argo_ready() {
    local n
    n="$(kubectl get applications.argoproj.io -n argocd -l okdp.io/instance -o json 2>/dev/null \
      | jq '[.items[] | select(.status.sync.status == "Synced" and .status.health.status == "Healthy"
          and .status.operationState.phase == "Succeeded")] | length')"
    # The operation too: an Application stays Synced/Healthy while a failing hook
    # (e.g. a schema Job) keeps its sync operation retrying.
    log "Applications synced and healthy, last sync succeeded: ${n:-0}/$expected"
    [[ "${n:-0}" == "$expected" ]]
  }
  wait_for "Applications synced and healthy" argo_ready
  kubectl get applications.argoproj.io -n argocd
fi
log "done; KUBECONFIG=$KUBECONFIG"
