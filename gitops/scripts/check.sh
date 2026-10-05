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

# CI check of the deployments repository layout (see gitops/README.md).
#
#   1. every YAML file parses;
#   2. platform-values.yaml, catalog.yaml, project.yaml and connection files have
#      the expected shape; connection files match their contract schema when the
#      okdp-lib contract schemas are available (--contracts DIR);
#   3. the generated files (compiled/, flux/components.yaml) are up to date, byte
#      for byte: okdp-gitops compile --check validates every declaration, compiles
#      every instance (its parameters, connections and upstream values against its
#      chart) and compares; the charts come from their registries, or first from
#      the packaged charts of --charts DIR (repeatable; scripts/pull-charts.sh);
#   4. the kustomizations build (when kustomize is installed);
#   5. with --helm: every instance renders with `helm template` and its compiled
#      values, which also validates the charts' values.schema.json (network, or
#      the --charts directories). --chart-map FROM=TO rewrites the chart reference
#      prefix FROM to TO (e.g. a local registry holding unpublished charts;
#      --plain-http applies to the rewritten references only).
#
# Usage: check.sh [--root DIR] [--path-prefix PREFIX] [--contracts DIR] [--charts DIR]...
#                 [--helm [--chart-map FROM=TO]... [--plain-http]]
# Requires bash >= 4, yq v4, jq, okdp-gitops (okdp-control-plane-server: make
# build-gitops; OKDP_GITOPS names it); optional: kustomize, helm.

set -euo pipefail
export LC_ALL=C

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPTS/.." && pwd)"
PREFIX=""
PREFIX_SET=false
CONTRACTS=""
HELM=false
CHART_MAPS=()
PLAIN_HTTP=()
CHART_DIRS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="$(cd "$2" && pwd)"; shift 2 ;;
    --path-prefix) PREFIX="$2"; PREFIX_SET=true; shift 2 ;;
    --contracts) CONTRACTS="$2"; shift 2 ;;
    --charts) CHART_DIRS+=("$(cd "$2" && pwd)"); shift 2 ;;
    --helm) HELM=true; shift ;;
    --chart-map) CHART_MAPS+=("$2"); shift 2 ;;
    --plain-http) PLAIN_HTTP=(--plain-http); shift ;;
    -h|--help) sed -n '18,39p' "$0"; exit 0 ;;
    *) echo "check: unknown argument: $1" >&2; exit 2 ;;
  esac
done

if ! $PREFIX_SET; then
  PREFIX="$(git -C "$ROOT" rev-parse --show-prefix 2>/dev/null || true)"
fi
PREFIX="${PREFIX%/}"

if [[ -z "$CONTRACTS" ]]; then
  # A checkout of okdp-lib-chart next to this repository.
  for d in "$ROOT/../../okdp-lib-chart/contracts" "$ROOT/../okdp-lib-chart/contracts" \
           "$ROOT/../../okdp-lib/contracts" "$ROOT/../okdp-lib/contracts"; do
    if [[ -d "$d" ]]; then CONTRACTS="$(cd "$d" && pwd)"; break; fi
  done
fi

failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }
step() { echo "== $*"; }

KNOWN_CONTRACTS="database-server s3 hive iceberg-catalog trino"

# ------------------------------------------------------------------ 1. YAML
step "YAML syntax"
while IFS= read -r f; do
  yq -e 'true' "$f" >/dev/null 2>&1 || [[ ! -s "$f" ]] || fail "${f#"$ROOT"/}: invalid YAML"
done < <(find "$ROOT" -path "$ROOT/.git" -prune -o -type f \( -name '*.yaml' -o -name '*.yml' \) -print | sort)

# ----------------------------------------------------------------- 2. shapes
step "platform files"
pv="$ROOT/platform/platform-values.yaml"
if [[ ! -f "$pv" ]]; then
  fail "platform/platform-values.yaml is missing"
else
  [[ "$(yq '[keys[]] | join(",")' "$pv")" == "global" ]] || fail "platform/platform-values.yaml: the only top-level key is global"
  [[ "$(yq '.global | [keys[]] | join(",")' "$pv")" == "okdp" ]] || fail "platform/platform-values.yaml: the only key under global is okdp"
  [[ "$(yq '.global.okdp | has("serviceCatalog")' "$pv")" == "false" ]] || fail "platform/platform-values.yaml: serviceCatalog belongs in platform/catalog.yaml"
fi
cat="$ROOT/platform/catalog.yaml"
if [[ ! -f "$cat" ]]; then
  fail "platform/catalog.yaml is missing"
else
  [[ "$(yq '.categories | tag' "$cat")" == "!!seq" ]] || fail "platform/catalog.yaml: categories must be a list"
  bad="$(yq '[.categories[] | select((.title | tag) != "!!str" or (.services | tag) != "!!seq")] | length' "$cat")"
  [[ "$bad" == "0" ]] || fail "platform/catalog.yaml: every category needs a title and a services list"
  bad="$(yq '[.categories[].services[] | select((.name | tag) != "!!str" or (.default | tag) != "!!str" or (.versions | tag) != "!!seq")] | length' "$cat")"
  [[ "$bad" == "0" ]] || fail "platform/catalog.yaml: every service needs name, versions and default (strings)"
fi

step "connections (platform and projects)"
if [[ -n "$CONTRACTS" ]]; then
  echo "   contract schemas: $CONTRACTS"
else
  echo "   contract schemas: not found (pass --contracts DIR); checking the shape only"
fi
# check_connection FILE: one connection file ({connections: {<c>: {...}}}).
check_connection() {
  local f="$1" rel c contract schema fields problems m
  rel="${f#"$ROOT"/}"; c="${f##*/}"; c="${c%.yaml}"
  [[ "$(yq '[keys[]] | join(",")' "$f")" == "connections" ]] || { fail "$rel: the only top-level key is connections"; return; }
  [[ "$(yq '.connections | [keys[]] | join(",")' "$f")" == "$c" ]] || { fail "$rel: must define exactly connections.$c"; return; }
  contract="$(yq ".connections[\"$c\"].contract" "$f")"
  [[ " $KNOWN_CONTRACTS " == *" $contract "* ]] || { fail "$rel: unknown contract '$contract'"; return; }
  schema="$CONTRACTS/$contract.schema.json"
  if [[ -n "$CONTRACTS" && -f "$schema" ]]; then
    # secretRef only for contracts with secret fields (the others have no Secret).
    if [[ "$(jq '[.properties[]? | select(.["x-okdp-secret"] == true)] | length' "$schema")" != "0" ]]; then
      [[ "$(yq ".connections[\"$c\"].secretRef.name | tag" "$f")" == "!!str" ]] || fail "$rel: secretRef.name is required"
    fi
    fields="$(yq -o=json ".connections[\"$c\"] | del(.contract) | del(.secretRef)" "$f")"
    # unknown fields, secret fields present, required non-secret fields missing
    problems="$(jq -rn --argjson v "$fields" --slurpfile s "$schema" '
      ($s[0].properties // {}) as $props
      | [ ($v | keys[]) as $k
          | if ($props | has($k)) | not then "unknown field \($k)"
            elif $props[$k]["x-okdp-secret"] == true then "secret field \($k) must be in the Secret, not here"
            else empty end ]
        + [ ($s[0].required // [])[] as $r
            | select(($props[$r]["x-okdp-secret"] // false) == false)
            | select(($v | has($r)) | not) | "missing required field \($r)" ]
      | .[]')"
    while IFS= read -r m; do [[ -z "$m" ]] || fail "$rel: $m"; done <<<"$problems"
  elif [[ "$contract" == s3 || "$contract" == database-server ]]; then
    [[ "$(yq ".connections[\"$c\"].secretRef.name | tag" "$f")" == "!!str" ]] || fail "$rel: secretRef.name is required"
  fi
}

for f in "$ROOT"/platform/connections/*.yaml "$ROOT"/projects/*/connections/*.yaml; do
  [[ -f "$f" ]] && check_connection "$f"
done

# ------------------------------------------------------- 3. generated files
step "compiled files are up to date (okdp-gitops compile --check)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
charts=()
for d in "${CHART_DIRS[@]}"; do charts+=(--charts "$d"); done
if ! command -v "${OKDP_GITOPS:-okdp-gitops}" >/dev/null; then
  fail "okdp-gitops is required (okdp-control-plane-server: make build-gitops; or set OKDP_GITOPS)"
elif ! "${OKDP_GITOPS:-okdp-gitops}" compile --check --root "$ROOT" --path-prefix "$PREFIX" "${charts[@]}" >"$TMP/.compile.log" 2>&1; then
  sed 's/^/   /' "$TMP/.compile.log"
  fail "the compiled files are stale or the layout does not compile: run okdp-gitops compile and commit the result"
fi

# ------------------------------------------------------------ 4. kustomize
if command -v kustomize >/dev/null; then
  step "kustomize build"
  dirs=("$ROOT/flux" "$ROOT/compiled/platform")
  for d in "$ROOT"/compiled/projects/*/ "$ROOT"/compiled/platform/components/*/; do
    [[ -f "$d/kustomization.yaml" ]] && dirs+=("${d%/}")
  done
  for d in "${dirs[@]}"; do
    kustomize build "$d" >/dev/null 2>"$TMP/.kustomize.log" \
      || { fail "kustomize build ${d#"$ROOT"/}"; sed 's/^/   /' "$TMP/.kustomize.log"; }
  done
else
  step "kustomize build: skipped (kustomize not installed)"
fi

# ----------------------------------------------------------------- 5. helm
if $HELM; then
  step "helm template with the compiled values"
  command -v helm >/dev/null || { fail "--helm needs helm"; }
  while IFS= read -r inst; do
    dir="$(dirname "$inst")"; rel="${dir#"$ROOT"/}"
    name="$(yq '.name' "$inst")"; project="$(yq '.project' "$inst")"
    chart="$(yq '.chart' "$inst")"; version="$(yq '.version' "$inst")"
    plain=() source=(--version "$version")
    for m in "${CHART_MAPS[@]}"; do
      if [[ "$chart" == "${m%%=*}"* ]]; then chart="${m#*=}${chart#"${m%%=*}"}"; plain=("${PLAIN_HTTP[@]}"); fi
    done
    for d in "${CHART_DIRS[@]}"; do
      if [[ -f "$d/${chart##*/}-$version.tgz" ]]; then chart="$d/${chart##*/}-$version.tgz"; plain=() source=(); break; fi
    done
    if helm template "$project-$name" "$chart" "${source[@]}" -n "$project" "${plain[@]}" -f "$ROOT/compiled/$rel/values.yaml" \
         >"$TMP/.helm.out" 2>"$TMP/.helm.log"; then
      echo "   ok $rel ($(grep -c '^kind:' "$TMP/.helm.out") objects)"
    else
      fail "helm template $rel"; grep -v 'failed to load plugins' "$TMP/.helm.log" | sed 's/^/   /'
    fi
  done < <(find "$ROOT/projects" "$ROOT/platform/components" -name instance.yaml 2>/dev/null | sort)
fi

if (( failures > 0 )); then
  echo "check: $failures failure(s)" >&2
  exit 1
fi
echo "check: OK"
