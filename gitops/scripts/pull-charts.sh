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

# Pulls the chart of every instance of the layout (platform components and project
# services, optional/ included) into DIR, as helm pull names them
# (<chart>-<version>.tgz): what okdp-gitops compile --charts DIR and check.sh --charts DIR
# serve before the registries, for charts not published yet, e.g. the packages a chart
# repository's CI pushed to its ghcr.io path.
#
#   --map FROM=TO   pull a chart reference starting with FROM from TO instead (repeatable,
#                   the first match wins), e.g.
#                   oci://quay.io/okdp/platform-charts=oci://ghcr.io/okdp/platform-charts
#   --plain-http    the mapped registries are reached over plain HTTP
#   --mapped-only   pull only the charts a --map rewrites (the others come from their
#                   registries at compile time)
# A chart already in DIR is not pulled again.
#
# Usage: pull-charts.sh [--root DIR] [--map FROM=TO]... [--plain-http] [--mapped-only] DIR
# Requires bash >= 4, yq v4, helm.

set -euo pipefail

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPTS/.." && pwd)"
MAPS=()
PLAIN_HTTP=()
MAPPED_ONLY=false
OUT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="$(cd "$2" && pwd)"; shift 2 ;;
    --map) MAPS+=("$2"); shift 2 ;;
    --plain-http) PLAIN_HTTP=(--plain-http); shift ;;
    --mapped-only) MAPPED_ONLY=true; shift ;;
    -h|--help) sed -n '18,33p' "$0"; exit 0 ;;
    -*) echo "pull-charts: unknown option: $1" >&2; exit 2 ;;
    *) OUT="$1"; shift ;;
  esac
done
[[ -n "$OUT" ]] || { echo "usage: pull-charts.sh [--root DIR] [--map FROM=TO]... [--plain-http] [--mapped-only] DIR" >&2; exit 2; }
mkdir -p "$OUT"

failures=0
while IFS=$'\t' read -r chart version; do
  name="${chart##*/}"
  [[ -f "$OUT/$name-$version.tgz" ]] && continue
  ref="$chart" plain=()
  for m in "${MAPS[@]}"; do
    if [[ "$chart" == "${m%%=*}"/* ]]; then
      ref="${m#*=}${chart#"${m%%=*}"}"; plain=("${PLAIN_HTTP[@]}"); break
    fi
  done
  if $MAPPED_ONLY && [[ "$ref" == "$chart" ]]; then continue; fi
  if helm pull "$ref" --version "$version" -d "$OUT" "${plain[@]}" >/dev/null 2>"$OUT/.pull.log"; then
    echo "pulled $ref:$version"
  else
    echo "FAIL: $ref:$version: $(grep -v 'failed to load plugins' "$OUT/.pull.log")" >&2
    failures=$((failures + 1))
  fi
done < <(find "$ROOT/platform/components" "$ROOT/projects" "$ROOT/optional" -name instance.yaml 2>/dev/null \
  | sort | xargs -r yq -r '.chart + "\t" + .version' | sort -u)
rm -f "$OUT/.pull.log"
(( failures == 0 )) || { echo "pull-charts: $failures chart(s) not pulled" >&2; exit 1; }
