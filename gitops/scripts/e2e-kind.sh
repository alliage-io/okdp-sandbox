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
# current context is never used), Gitea bootstrapped with helm from the 20-gitea
# component (then adopted by the engine), the layout pushed to
# http://gitea-http.gitea.svc.cluster.local:3000/okdp/okdp-sandbox.git (branch main),
# the engine, its entry point, then a wait until every release is ready.
#
# What is pushed is a copy of the layout at E2E_REF, adapted for the test:
#   - the control plane server's gitops.engine is set to the engine under test;
#   - E2E_CHART_MAP rewrites chart references (unpublished charts in a local
#     registry) in every instance.yaml and in the catalog, then render-flux.sh runs;
#   - E2E_PLAIN_HTTP_REGISTRY (host:port) is reached over plain HTTP: Flux
#     OCIRepositories get spec.insecure (Kustomization patches), Argo CD gets one
#     repository Secret per chart repository (insecureOCIForceHttp), the server
#     gets insecureOciRegistries;
#   - E2E_SKIP_PROJECTS=1 drops projects/ (platform only).
#
# Usage:
#   e2e-kind.sh up   <flux|argocd>   create, deploy and wait
#   e2e-kind.sh push <flux|argocd>   push E2E_REF again (adapted) to the cluster's Gitea
#   e2e-kind.sh down <flux|argocd>   delete the cluster
# Environment:
#   E2E_DIR       work directory (kubeconfigs, pushed copy), default ./.e2e
#   E2E_REF       Git ref of this repository to deploy, default HEAD (commit first)
#   E2E_CHART_MAP "FROM=TO" chart reference prefix rewrite, e.g.
#                 oci://quay.io/okdp=oci://nokubocd-registry:5000/okdp
#   E2E_PLAIN_HTTP_REGISTRY  e.g. nokubocd-registry:5000
#   E2E_REGISTRY_CONTAINER   Docker container of that registry, connected to the kind network
#   E2E_LOAD_IMAGES          images loaded into the kind node (space separated)
#   E2E_SKIP_PROJECTS        1: platform components only
#   FLUX_VERSION  default v2.9.5          ARGOCD_VERSION  default v3.4.2
#   E2E_TIMEOUT   seconds, default 2400
# Afterwards: KUBECONFIG=$E2E_DIR/<engine>.kubeconfig kubectl ...

set -euo pipefail

ACTION="${1:-}"; ENGINE="${2:-}"
[[ "$ACTION" =~ ^(up|push|down)$ && "$ENGINE" =~ ^(flux|argocd)$ ]] || { sed -n '18,54p' "$0"; exit 2; }

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
  yq -i ".gitops.engine = \"$ENGINE\"" "$g/platform/components/30-okdp-control-plane-server/values.yaml"
  if [[ -n "$E2E_CHART_MAP" ]]; then
    local from="${E2E_CHART_MAP%%=*}" to="${E2E_CHART_MAP#*=}"
    while IFS= read -r f; do
      FROM="$from" TO="$to" yq -i '.chart |= sub("^" + strenv(FROM); strenv(TO))' "$f"
    done < <(find "$g" -name instance.yaml -not -path "$g/optional/*")
    FROM="$from" TO="$to" yq -i '.defaultRepository |= sub("^" + strenv(FROM); strenv(TO))' "$g/platform/catalog.yaml"
  fi
  if [[ -n "$E2E_PLAIN_HTTP_REGISTRY" ]]; then
    yq -i ".insecureOciRegistries = \"$E2E_PLAIN_HTTP_REGISTRY\"" "$g/platform/components/30-okdp-control-plane-server/values.yaml"
  fi
  "$g/scripts/render-flux.sh" --root "$g" --path-prefix "$PREFIX" >/dev/null
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

GITEA_USER="$(yq '.gitea.admin.username' "$ROOT/platform/components/20-gitea/values.yaml")"
GITEA_PASSWORD="$(yq '.gitea.admin.password' "$ROOT/platform/components/20-gitea/values.yaml")"

push_copy() {
  log "pushing $E2E_REF (adapted) to okdp/okdp-sandbox main"
  kubectl -n gitea port-forward svc/gitea-http 0:3000 >"$E2E_DIR/$ENGINE.pf.log" 2>&1 &
  local pf=$! port=""
  for _ in $(seq 30); do
    port="$(sed -n 's/.*127.0.0.1:\([0-9]*\) ->.*/\1/p' "$E2E_DIR/$ENGINE.pf.log" | head -n 1)"
    [[ -n "$port" ]] && break
    sleep 1
  done
  [[ -n "$port" ]] || { log "port-forward failed"; cat "$E2E_DIR/$ENGINE.pf.log"; kill $pf; exit 1; }
  git -C "$COPY" push -q --force "http://$GITEA_USER:$GITEA_PASSWORD@127.0.0.1:$port/okdp/okdp-sandbox.git" main
  kill $pf 2>/dev/null || true
}

if [[ "$ACTION" == push ]]; then
  prepare_copy; push_copy; exit 0
fi

# ------------------------------------------------------------------ cluster
if kind get clusters | grep -qx "$CLUSTER"; then
  log "cluster exists"
  kind export kubeconfig --name "$CLUSTER" --kubeconfig "$KUBECONFIG"
else
  kind create cluster --name "$CLUSTER" --kubeconfig "$KUBECONFIG" --wait 120s
fi
[[ "$(kubectl config current-context)" == "kind-$CLUSTER" ]] || { log "unexpected context"; exit 1; }
if [[ -n "$E2E_REGISTRY_CONTAINER" ]]; then
  docker network connect kind "$E2E_REGISTRY_CONTAINER" 2>/dev/null || true
fi
for image in $E2E_LOAD_IMAGES; do
  kind load docker-image "$image" --name "$CLUSTER"
done

prepare_copy

# -------------------------------------------------------------------- gitea
# Bootstrap: the same release the engine manages afterwards (gitea-gitea in gitea),
# with the component's values layers.
g="$ROOT/platform/components/20-gitea"
log "installing Gitea (bootstrap of the 20-gitea component)"
helm upgrade --install "$(yq '.project + "-" + .name' "$g/instance.yaml")" "$(yq '.chart' "$g/instance.yaml")" \
  --version "$(yq '.version' "$g/instance.yaml")" -n "$(yq '.project' "$g/instance.yaml")" --create-namespace \
  -f "$ROOT/platform/platform-values.yaml" -f "$g/values.yaml" --wait --timeout 10m
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
