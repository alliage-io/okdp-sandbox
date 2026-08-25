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

# End-to-end test of one GitOps engine on a throwaway kind cluster:
# kind cluster nokubocd-<engine> (own kubeconfig, the current context is never used),
# Gitea (upstream chart) serving this repository at
# http://gitea-http.gitea.svc.cluster.local:3000/okdp/okdp-sandbox.git (branch main),
# the engine, the entry point, then a wait until every release is ready.
#
# Usage:
#   e2e-kind.sh up   <flux|argocd>   create, deploy and wait
#   e2e-kind.sh down <flux|argocd>   delete the cluster
# Environment:
#   E2E_DIR       work directory (kubeconfigs), default ./.e2e
#   E2E_REF       Git ref pushed to Gitea's main branch, default HEAD (commit first)
#   FLUX_VERSION  default v2.9.5          ARGOCD_VERSION  default v3.4.2
#   GITEA_CHART_VERSION  default 12.7.0   E2E_TIMEOUT  seconds, default 900
# Afterwards: KUBECONFIG=$E2E_DIR/<engine>.kubeconfig kubectl ...

set -euo pipefail

ACTION="${1:-}"; ENGINE="${2:-}"
[[ "$ACTION" =~ ^(up|down)$ && "$ENGINE" =~ ^(flux|argocd)$ ]] || { sed -n '18,33p' "$0"; exit 2; }

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPTS/.." && pwd)"
E2E_DIR="$(mkdir -p "${E2E_DIR:-./.e2e}" && cd "${E2E_DIR:-./.e2e}" && pwd)"
E2E_REF="${E2E_REF:-HEAD}"
FLUX_VERSION="${FLUX_VERSION:-v2.9.5}"
ARGOCD_VERSION="${ARGOCD_VERSION:-v3.4.2}"
GITEA_CHART_VERSION="${GITEA_CHART_VERSION:-12.7.0}"
E2E_TIMEOUT="${E2E_TIMEOUT:-900}"
CLUSTER="nokubocd-$ENGINE"
export KUBECONFIG="$E2E_DIR/$ENGINE.kubeconfig"
GITEA_USER=okdp
GITEA_PASSWORD=okdp-e2e-Passw0rd

log() { echo "[$CLUSTER] $*"; }

if [[ "$ACTION" == down ]]; then
  kind delete cluster --name "$CLUSTER" --kubeconfig "$KUBECONFIG"
  rm -f "$KUBECONFIG"
  exit 0
fi

# ------------------------------------------------------------------ cluster
if kind get clusters | grep -qx "$CLUSTER"; then
  log "cluster exists"
  kind export kubeconfig --name "$CLUSTER" --kubeconfig "$KUBECONFIG"
else
  kind create cluster --name "$CLUSTER" --kubeconfig "$KUBECONFIG" --wait 120s
fi
[[ "$(kubectl config current-context)" == "kind-$CLUSTER" ]] || { log "unexpected context"; exit 1; }

# -------------------------------------------------------------------- gitea
log "installing Gitea $GITEA_CHART_VERSION"
helm upgrade --install gitea oci://docker.gitea.com/charts/gitea --version "$GITEA_CHART_VERSION" \
  -n gitea --create-namespace --wait --timeout 10m -f - <<EOF
postgresql-ha: {enabled: false}
postgresql: {enabled: false}
valkey-cluster: {enabled: false}
valkey: {enabled: false}
persistence: {enabled: false}
test: {enabled: false}
gitea:
  admin: {username: $GITEA_USER, password: $GITEA_PASSWORD, email: okdp@example.org}
  config:
    database: {DB_TYPE: sqlite3}
    session: {PROVIDER: memory}
    cache: {ADAPTER: memory}
    queue: {TYPE: level}
    repository: {ENABLE_PUSH_CREATE_USER: true, DEFAULT_PUSH_CREATE_PRIVATE: false}
EOF

log "pushing $E2E_REF to okdp/okdp-sandbox main"
kubectl -n gitea port-forward svc/gitea-http 0:3000 >"$E2E_DIR/$ENGINE.pf.log" 2>&1 &
PF=$!
trap 'kill $PF 2>/dev/null || true' EXIT
for _ in $(seq 30); do
  PORT="$(sed -n 's/.*127.0.0.1:\([0-9]*\) ->.*/\1/p' "$E2E_DIR/$ENGINE.pf.log" | head -n 1)"
  [[ -n "$PORT" ]] && break
  sleep 1
done
[[ -n "${PORT:-}" ]] || { log "port-forward failed"; cat "$E2E_DIR/$ENGINE.pf.log"; exit 1; }
git -C "$ROOT" push --force "http://$GITEA_USER:$GITEA_PASSWORD@127.0.0.1:$PORT/okdp/okdp-sandbox.git" \
  "$E2E_REF:refs/heads/main"
kill $PF 2>/dev/null || true

# ------------------------------------------------------------------- engine
wait_for() {  # wait_for DESCRIPTION COMMAND...: retry until COMMAND succeeds
  local what="$1"; shift
  local deadline=$((SECONDS + E2E_TIMEOUT))
  until "$@"; do
    (( SECONDS < deadline )) || { log "timeout waiting for $what"; return 1; }
    sleep 10
  done
  log "$what: ok"
}

expected="$(find "$ROOT/projects" "$ROOT/platform/components" -name instance.yaml | wc -l)"

if [[ "$ENGINE" == flux ]]; then
  log "installing Flux $FLUX_VERSION"
  flux install --version="$FLUX_VERSION" --components=source-controller,kustomize-controller,helm-controller
  # Chart version without the OCI digest (see gitops/README.md, "Install with Flux").
  kubectl -n flux-system patch deployment helm-controller --type json \
    -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--feature-gates=DisableChartDigestTracking=true"}]'
  kubectl -n flux-system rollout status deployment helm-controller --timeout=5m
  kubectl apply -f "$ROOT/flux/sync.yaml"
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
  kubectl apply -n argocd -f "$ROOT/argocd/"
  argo_ready() {
    local n
    n="$(kubectl get applications.argoproj.io -n argocd -l okdp.io/instance -o json 2>/dev/null \
      | jq '[.items[] | select(.status.sync.status == "Synced" and .status.health.status == "Healthy")] | length')"
    log "Applications synced and healthy: ${n:-0}/$expected"
    [[ "${n:-0}" == "$expected" ]]
  }
  wait_for "Applications synced and healthy" argo_ready
  kubectl get applications.argoproj.io -n argocd
fi
log "done; KUBECONFIG=$KUBECONFIG"
