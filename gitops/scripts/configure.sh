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

# Chooses the GitOps engine and the object store of the sandbox, in the layout only
# (nothing is applied to a cluster; commit and push the result to Forgejo):
#   --engine flux|argocd        gitops.engine of 30-okdp-control-plane-server (the
#                               console writes for that engine);
#   --storage seaweedfs|rustfs  the chart of 20-storage. The active store lives in
#                               platform/components/20-storage, the others are parked
#                               in optional/storage/<store> (instance.yaml, values.yaml):
#                               the two are swapped, the internalUrl of the connection
#                               files pointing at the store is rewritten, then
#                               render-flux.sh runs.
# Without --engine and --storage on a terminal, or with -i, asks for both (the current
# values are the defaults). Choose before the first install: switching the store of a
# running sandbox starts from an empty store, switching engines means reinstalling.
#
# Usage: configure.sh [-i|--interactive] [--engine flux|argocd]
#                     [--storage seaweedfs|rustfs] [--root DIR]
#        configure.sh --show
# Requires bash >= 4, yq v4.

set -euo pipefail
export LC_ALL=C

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPTS/.." && pwd)"
ENGINE=""
STORAGE=""
INTERACTIVE=false
SHOW=false

ENGINES=(flux argocd)
STORES=(seaweedfs rustfs)

while [[ $# -gt 0 ]]; do
  case "$1" in
    --engine) ENGINE="$2"; shift 2 ;;
    --storage) STORAGE="$2"; shift 2 ;;
    -i|--interactive) INTERACTIVE=true; shift ;;
    --show) SHOW=true; shift ;;
    --root) ROOT="$(cd "$2" && pwd)"; shift 2 ;;
    -h|--help) sed -n '18,35p' "$0"; exit 0 ;;
    *) echo "configure: unknown argument: $1" >&2; exit 2 ;;
  esac
done

command -v yq >/dev/null || { echo "configure: yq v4 is required" >&2; exit 2; }
yq --version 2>&1 | grep -q 'version v4' || { echo "configure: yq v4 (mikefarah) is required" >&2; exit 2; }

SERVER_VALUES="$ROOT/platform/components/30-okdp-control-plane-server/values.yaml"
STORE_DIR="$ROOT/platform/components/20-storage"
PARKED="$ROOT/optional/storage"

one_of() { # value choices...
  local v="$1"; shift
  local c; for c in "$@"; do [[ "$v" == "$c" ]] && return 0; done
  return 1
}

# In-cluster S3 endpoint of a store: store release namespace.
internal_url() {
  case "$1" in
    seaweedfs) echo "http://$2-s3.$3.svc.cluster.local:8333" ;;
    rustfs) echo "http://$2-svc.$3.svc.cluster.local:9000" ;;
  esac
}

CUR_ENGINE="$(yq '.gitops.engine // ""' "$SERVER_VALUES")"
CUR_STORAGE="$(yq '.service // ""' "$STORE_DIR/instance.yaml")"
one_of "$CUR_ENGINE" "${ENGINES[@]}" \
  || { echo "configure: unexpected gitops.engine '$CUR_ENGINE' in ${SERVER_VALUES#"$ROOT"/}" >&2; exit 1; }
one_of "$CUR_STORAGE" "${STORES[@]}" \
  || { echo "configure: unexpected service '$CUR_STORAGE' in ${STORE_DIR#"$ROOT"/}/instance.yaml" >&2; exit 1; }

if $SHOW; then
  echo "engine:  $CUR_ENGINE"
  echo "storage: $CUR_STORAGE"
  exit 0
fi

# Numbered menu on stderr; prints the choice. Enter keeps the default.
ask() { # prompt default choices...
  local prompt="$1" def="$2"; shift 2
  local i reply
  echo "$prompt" >&2
  i=1
  for c in "$@"; do
    printf '  %d) %s%s\n' "$i" "$c" "$([[ "$c" == "$def" ]] && echo ' (current)')" >&2
    i=$((i + 1))
  done
  while true; do
    read -r -p "Choice [$def]: " reply </dev/tty >&2 || exit 1
    [[ -z "$reply" ]] && { echo "$def"; return; }
    if [[ "$reply" =~ ^[0-9]+$ ]] && (( reply >= 1 && reply <= $# )); then
      echo "${!reply}"; return
    fi
    one_of "$reply" "$@" && { echo "$reply"; return; }
    echo "  answer 1-$#, a name, or Enter" >&2
  done
}

if [[ -z "$ENGINE" && -z "$STORAGE" && -t 0 ]]; then
  INTERACTIVE=true
fi
if $INTERACTIVE; then
  [[ -r /dev/tty ]] || { echo "configure: --interactive needs a terminal" >&2; exit 2; }
  [[ -n "$ENGINE" ]] || ENGINE="$(ask "GitOps engine:" "$CUR_ENGINE" "${ENGINES[@]}")"
  [[ -n "$STORAGE" ]] || STORAGE="$(ask "Object store (20-storage):" "$CUR_STORAGE" "${STORES[@]}")"
  echo >&2
  echo "engine:  $CUR_ENGINE -> $ENGINE" >&2
  echo "storage: $CUR_STORAGE -> $STORAGE" >&2
  if [[ "$ENGINE" == "$CUR_ENGINE" && "$STORAGE" == "$CUR_STORAGE" ]]; then
    echo "Nothing to change." >&2
    exit 0
  fi
  read -r -p "Apply? [Y/n] " reply </dev/tty >&2 || exit 1
  [[ -z "$reply" || "$reply" =~ ^[Yy] ]] || { echo "Aborted." >&2; exit 1; }
fi

if [[ -z "$ENGINE" && -z "$STORAGE" ]]; then
  echo "configure: nothing to do (--engine, --storage or -i; --help)" >&2
  exit 2
fi
ENGINE="${ENGINE:-$CUR_ENGINE}"
STORAGE="${STORAGE:-$CUR_STORAGE}"
one_of "$ENGINE" "${ENGINES[@]}" || { echo "configure: --engine: one of ${ENGINES[*]}" >&2; exit 2; }
one_of "$STORAGE" "${STORES[@]}" || { echo "configure: --storage: one of ${STORES[*]}" >&2; exit 2; }

changed=false

if [[ "$ENGINE" != "$CUR_ENGINE" ]]; then
  # Line edit, so that the file keeps its comments and layout byte for byte.
  sed -i -E "s/^(  engine: )$CUR_ENGINE\$/\1$ENGINE/" "$SERVER_VALUES"
  [[ "$(yq '.gitops.engine' "$SERVER_VALUES")" == "$ENGINE" ]] \
    || { echo "configure: could not set gitops.engine in ${SERVER_VALUES#"$ROOT"/}" >&2; exit 1; }
  echo "engine: $CUR_ENGINE -> $ENGINE (${SERVER_VALUES#"$ROOT"/})"
  changed=true
fi

if [[ "$STORAGE" != "$CUR_STORAGE" ]]; then
  [[ -f "$PARKED/$STORAGE/instance.yaml" && -f "$PARKED/$STORAGE/values.yaml" ]] \
    || { echo "configure: ${PARKED#"$ROOT"/}/$STORAGE/{instance,values}.yaml missing" >&2; exit 1; }
  [[ ! -e "$PARKED/$CUR_STORAGE" ]] \
    || { echo "configure: ${PARKED#"$ROOT"/}/$CUR_STORAGE already exists, cannot park the current store" >&2; exit 1; }

  name="$(yq '.name' "$STORE_DIR/instance.yaml")"
  project="$(yq '.project' "$STORE_DIR/instance.yaml")"
  old_url="$(internal_url "$CUR_STORAGE" "$project-$name" "$project")"
  new_url="$(internal_url "$STORAGE" "$project-$name" "$project")"

  mkdir -p "$PARKED/$CUR_STORAGE"
  mv "$STORE_DIR/instance.yaml" "$STORE_DIR/values.yaml" "$PARKED/$CUR_STORAGE/"
  mv "$PARKED/$STORAGE/instance.yaml" "$PARKED/$STORAGE/values.yaml" "$STORE_DIR/"
  rmdir "$PARKED/$STORAGE"
  echo "storage: $CUR_STORAGE -> $STORAGE (${STORE_DIR#"$ROOT"/}; $CUR_STORAGE parked in ${PARKED#"$ROOT"/}/$CUR_STORAGE)"

  while IFS= read -r f; do
    OLD="$old_url" NEW="$new_url" yq -i \
      '(.connections[] | select(.internalUrl == strenv(OLD)) | .internalUrl) = strenv(NEW)' "$f"
    echo "  internalUrl -> $new_url (${f#"$ROOT"/})"
  done < <(grep -rlF --include='*.yaml' "$old_url" "$ROOT/projects" "$ROOT/platform/connections" 2>/dev/null | sort)
  changed=true
fi

if $changed; then
  "$SCRIPTS/render-flux.sh" --root "$ROOT"
  cat <<EOF

Next: review, commit and push to Forgejo (README, step 3), then install with
$([[ "$ENGINE" == flux ]] && echo "Flux (README, step 4a)." || echo "Argo CD (README, step 4b).")
EOF
else
  echo "Already engine=$ENGINE storage=$STORAGE; nothing changed."
fi
