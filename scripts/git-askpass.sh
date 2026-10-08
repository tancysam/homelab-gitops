#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  "Username for 'https://github.com': ")
    printf '%s\n' 'x-access-token'
    ;;
  "Password for 'https://x-access-token@github.com': ")
    TOKEN_FILE="${CREDENTIALS_DIRECTORY:-/etc/homelab}/github-token"
    TOKEN="$(< "$TOKEN_FILE")"
    test -n "$TOKEN"
    printf '%s\n' "$TOKEN"
    ;;
  *)
    printf 'Refusing an unexpected Git credential prompt.\n' >&2
    exit 1
    ;;
esac
