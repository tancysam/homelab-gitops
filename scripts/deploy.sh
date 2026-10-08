#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/hosts/docker-host/config.sh"

STACK="${1:?Usage: bash scripts/deploy.sh STACK}"

ENABLED=false
for name in "${STACKS[@]}"; do
  if [[ "$name" == "$STACK" ]]; then
    ENABLED=true
    break
  fi
done

if [[ "$ENABLED" != true ]]; then
  printf 'Stack is not enabled: %s\n' "$STACK" >&2
  exit 1
fi

command -v infisical >/dev/null
COMPOSE="$ROOT/stacks/$STACK/compose.yaml"
test -f "$COMPOSE"

exec 9>/run/lock/homelab-deploy.lock
flock -n 9 || {
  printf 'Another deployment is running.\n' >&2
  exit 1
}

: "${INFISICAL_UNIVERSAL_AUTH_CLIENT_ID:?Machine identity ID missing}"
: "${INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET:?Machine identity secret missing}"

INFISICAL_TOKEN="$(
  infisical login --method=universal-auth --silent --plain
)"
export INFISICAL_TOKEN

infisical run \
  --projectId="$INFISICAL_PROJECT_ID" \
  --env="$INFISICAL_ENV" \
  --path="/$STACK" \
  -- bash -c '
    set -euo pipefail

    compose=(docker compose -p "$1" -f "$2")

    if ! "${compose[@]}" config --quiet >/dev/null 2>&1; then
      printf "Compose validation failed; deployment aborted.\n" >&2
      exit 1
    fi

    "${compose[@]}" pull
    "${compose[@]}" up -d --wait --wait-timeout 180
  ' _ "$STACK" "$COMPOSE"