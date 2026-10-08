#!/usr/bin/env bash
set -euo pipefail
umask 077

fail() {
  printf '%s\n' "$*" >&2
  exit 1
}

main() {
  local root credentials revision stack state_dir
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  cd "$root"

  exec 8>/run/lock/homelab-sync.lock
  flock -n 8 || {
    printf 'Another sync is running; skipping this run.\n'
    return 0
  }

  exec 9>/run/lock/homelab-deploy.lock
  flock -n 9 || {
    printf 'A deployment is running; skipping this run.\n'
    return 0
  }

  [[ "$(git rev-parse --show-toplevel)" == "$root" ]] || fail 'Not at the homelab repository root.'
  [[ "$(git symbolic-ref --short HEAD)" == main ]] || fail 'Sync requires the main branch.'
  [[ -z "$(git status --porcelain --untracked-files=normal)" ]] || fail 'Commit and push local changes before syncing.'
  [[ "$(git remote get-url origin)" == 'https://github.com/tancysam/homelab-gitops.git' ]] || fail 'Unexpected origin URL; refusing to supply GitHub credentials.'

  command -v infisical >/dev/null
  command -v docker >/dev/null
  test -x "$root/scripts/git-askpass.sh"

  credentials="${CREDENTIALS_DIRECTORY:-/etc/homelab}"
  for credential in github-token infisical-client-id infisical-client-secret; do
    [[ -r "$credentials/$credential" && -s "$credentials/$credential" ]] || fail "Missing credential file: $credential"
  done

  export CREDENTIALS_DIRECTORY="$credentials"
  export GIT_ASKPASS="$root/scripts/git-askpass.sh"
  export GIT_TERMINAL_PROMPT=0
  export LC_ALL=C

  INFISICAL_UNIVERSAL_AUTH_CLIENT_ID="$(< "$credentials/infisical-client-id")"
  INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET="$(< "$credentials/infisical-client-secret")"
  export INFISICAL_UNIVERSAL_AUTH_CLIENT_ID INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET

  git -c credential.helper= -c credential.useHttpPath=false fetch --no-tags origin refs/heads/main:refs/remotes/origin/main
  git merge-base --is-ancestor HEAD refs/remotes/origin/main || fail 'Local main is ahead of or diverged from GitHub; refusing to deploy.'
  git merge --ff-only --no-edit refs/remotes/origin/main
  revision="$(git rev-parse HEAD)"

  STACKS=()
  source "$root/hosts/docker-host/config.sh"
  (( ${#STACKS[@]} > 0 )) || fail 'No stacks are enabled for this host.'

  for stack in "${STACKS[@]}"; do
    [[ "$stack" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || fail "Invalid stack name: $stack"
    [[ "$stack" != infisical && "$stack" != infinsical ]] || fail 'Infisical must be bootstrapped independently.'
    test -f "$root/stacks/$stack/compose.yaml" || fail "Missing Compose file for $stack."
  done

  state_dir="${STATE_DIRECTORY:-/var/lib/homelab-gitops}"
  install -d -m 700 -- "$state_dir"

  flock -u 9
  exec 9>&-

  for stack in "${STACKS[@]}"; do
    printf 'Reconciling %s at %s\n' "$stack" "$revision"
    if bash "$root/scripts/deploy.sh" "$stack"; then
      printf '%s\n' "$revision" > "$state_dir/$stack.revision.tmp"
      mv -- "$state_dir/$stack.revision.tmp" "$state_dir/$stack.revision"
    else
      fail "Deployment failed for $stack; it will be retried on the next sync."
    fi
  done

  printf 'Sync completed successfully at %s\n' "$revision"
}

main "$@"
