# Homelab GitOps

A pull-based workflow for managing Docker Compose applications with Git, Infisical, and systemd. Renovate proposes dependency updates, Gitleaks checks for committed secrets, and the host applies approved changes from `main`.

This is my personal homelab implementation. My previous issue was having to manually ssh into my homelab server to manage my various docker images and change the version numbers. I did not want to use automatic updates due to breaking changes. So the best way I found to do it is thorough GitOps, which is as you see through the live implementation of this repo.

## How it works

```text
Review and merge a pull request
              ↓
A systemd timer starts the host-side sync
              ↓
Git fetches main and fast-forwards a clean checkout
              ↓
Infisical supplies each stack's environment variables
              ↓
Compose validates configuration, pulls images, and applies changes
```

Three things are kept separate:

- **Git:** Compose files, non-secret application configuration, and deployment scripts.
- **Infisical:** application secret values, organized by stack.
- **Persistent storage:** databases, media, certificates, and other runtime data, backed up independently of Git.

## Repository structure

```text
.github/workflows/
  secrets-scanning.yml
hosts/docker-host/
  config.sh
  homelab-sync.service
  homelab-sync.timer
scripts/
  deploy.sh
  git-askpass.sh
  sync.sh
stacks/
  <application>/
    compose.yaml
renovate.json
```

| Component | Responsibility |
| --- | --- |
| [Host configuration](hosts/docker-host/config.sh) | Infisical connection settings and enabled stacks, in deployment order. |
| [Sync script](scripts/sync.sh) | Updates the checkout, loads credentials, and deploys enabled stacks. |
| [Deployment script](scripts/deploy.sh) | Authenticates to Infisical and deploys one enabled stack. |
| [Git authentication helper](scripts/git-askpass.sh) | Supplies a GitHub token without an interactive prompt. |
| [Systemd service](hosts/docker-host/homelab-sync.service) | Runs the sync with host credentials. |
| [Systemd timer](hosts/docker-host/homelab-sync.timer) | Schedules recurring syncs. |
| [Renovate configuration](renovate.json) | Controls dependency update proposals. |
| [Secret-scanning workflow](.github/workflows/secrets-scanning.yml) | Runs Gitleaks on GitHub. |

### Included stacks

| Directory | Application |
| --- | --- |
| `stacks/frigate` | Frigate |
| `stacks/immich` | Immich |
| `stacks/infinsical` | Infisical bootstrap deployment; directory spelling retained for compatibility. |
| `stacks/librechat` | LibreChat |
| `stacks/newt` | Newt |
| `stacks/npmauth` | Nginx Proxy Manager, TinyAuth, and Pocket ID |
| `stacks/stirlingpdf` | Stirling PDF |
| `stacks/termix` | Termix |
| `stacks/ytdlp` | yt-dlp Web UI |

A directory's presence does not enable deployment. The `STACKS` array in the host configuration determines what is managed.

Infisical is intentionally excluded from automatic sync. It must start independently using locally available bootstrap credentials, rather than depend on its own API to retrieve them.

## Deployment behavior

The timer is configured to run approximately two minutes after boot, then two minutes after each service run finishes.

- Sync requires a clean checkout on `main` and the expected origin URL.
- Only fast-forward updates are accepted. Local commits ahead of the remote or divergent history stop the sync.
- Locks prevent overlapping syncs and automated Git updates during an active deployment.
- Stacks deploy sequentially in their configured order.
- A failure stops that run; the next scheduled run retries from the beginning.
- Each successful deployment records its Git revision in `/var/lib/homelab-gitops/<stack>.revision`.

**Every enabled stack is reconciled on every run, even if Git has not changed.** This also picks up changes made only in Infisical. Compose normally leaves containers running when their images and resolved configuration are unchanged.

The deployment script validates configuration without printing resolved values, explicitly pulls images, then runs `up -d --pull never --wait --wait-timeout 180`. The `--pull never` flag prevents a second implicit pull; it does not disable the preceding pull step.

Use digest-pinned images for predictable deployments. Floating tags can change between syncs without a Git change.

There is no automatic rollback. Removing a stack from the enabled list stops managing it; it does not delete its containers or data. Earlier successful stack updates remain applied if a later stack fails.

## Secrets and local configuration

Each stack uses a matching folder in the configured Infisical environment, for example `/npmauth` or `/librechat`. The machine identity needs read access to every enabled stack's folder, including folders for stacks with no secret values.

Local `.env` files can reference values supplied by Infisical:

```dotenv
API_KEY=${API_KEY:?Secret missing}
OPTIONAL_SETTING=${OPTIONAL_SETTING:-}
```

The first entry requires a non-empty value. The second permits an empty value. Non-sensitive settings may remain literal values.

`infisical run` supplies variables to the Compose process. Services receive the variables explicitly configured through `environment` or `env_file`. The scripts do not export or rewrite `.env` files.

For applications that support it, mounted configuration can also reference container environment variables. For example, a supported LibreChat API-key field can use:

```yaml
apiKey: "${MY_API_KEY}"
```

**Fresh-checkout limitation:** local `.env` files are not included in Git, and the current ignore rules also exclude `.env.template`. Prepare the required reference files separately. If introducing tracked templates, review them for real secret values before explicitly allowing them into Git.

Environment injection is not an in-memory secrets vault. Docker stores container environment variables in its metadata, and Docker or host administrators can access them.

### Deployment credentials

The host expects these files outside the checkout:

| File | Contents |
| --- | --- |
| `/etc/homelab/github-token` | A GitHub token with read access to the configured repository. |
| `/etc/homelab/infisical-client-id` | An Infisical Universal Auth Client ID. |
| `/etc/homelab/infisical-client-secret` | Its valid Universal Auth Client Secret. |

Use root ownership, directory permissions `0700`, and file permissions `0600`. Each file contains only its value, not an assignment such as `NAME=value`. These are plaintext bootstrap credentials protected by filesystem permissions.

Systemd supplies them through `LoadCredential`. Direct execution of `sync.sh` falls back to `/etc/homelab`. Although a public GitHub repository may allow anonymous reads, the current script still requires the GitHub credential file.

The standalone deployment script expects `INFISICAL_UNIVERSAL_AUTH_CLIENT_ID` and `INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET` in its process environment. Prefer the systemd service for routine manual syncs so credential loading is handled consistently.

Do not invoke the password branch of `git-askpass.sh` directly: its output contains the token and is intended for Git to capture.

## Everyday operation

Prefer pull requests or a separate editing clone. Uncommitted changes in the deployment checkout intentionally blocks sync.

| Task | Command |
| --- | --- |
| Run a sync and deployment | `systemctl start homelab-sync.service` |
| Show the next scheduled run | `systemctl list-timers homelab-sync.timer` |
| Read recent deployment logs | `journalctl -u homelab-sync.service -n 50 --no-pager` |
| Inspect the last result | `systemctl show homelab-sync.service -p Result -p ExecMainStatus` |
| Pause future automatic runs | `systemctl disable --now homelab-sync.timer` |
| Resume automatic runs | `systemctl enable --now homelab-sync.timer` |

Pausing the timer does not stop a running sync or application containers.

### Add an application

1. Add its reviewed Compose file and non-secret supporting configuration under `stacks/<name>/`.
2. Prepare persistent storage and any required networks, devices, or supporting files.
3. Preserve the intended Compose project name. This implementation uses the stack folder name as the project name.
4. Create its Infisical folder, grant read access, and prepare local references.
5. Add the name to `STACKS` in deployment order, then review, commit, and push.

The next sync will attempt to start the services enabled by that Compose file. Infisical itself remains a separate bootstrap deployment.

## Dependency updates and secret scanning

### Renovate

Install the Renovate GitHub App for your repository. The included configuration requests Docker and GitHub Actions digest pinning, a seven-day minimum release age where supported, manual merging, and at most three open PRs. The default PR creation limit is two per hour.

Keep image versions in tracked Compose configuration so Renovate can inspect them. Review application release notes and backup requirements before merging, particularly for databases and coupled services such as Immich's server and machine-learning images.

### Gitleaks

The included workflow runs on pushes to `main`, pull requests, manual dispatch, and daily at 03:00 UTC. It scans Git content and history, not ignored files on the deployment host. PR comments and scan artifact uploads are disabled. The workflow does not need Infisical credentials or the host's GitHub token.

CI runs after content reaches GitHub. Use push protection or a local pre-commit scanner where available to reduce the chance of uploading secrets in the first place. Scanner success is not proof that a change is safe or that every secret has been detected.


