# CLAUDE.md — AzerothCore friends server

## What this repo is

Fork of `azerothcore/azerothcore-wotlk`. It exists for exactly two reasons:

1. Pin the modules we run (as git submodules under `modules/`).
2. Build our own Docker images in CI and publish them to GHCR.

The server itself runs at home: Dokploy inside an LXC on a Proxmox host, alongside other Docker services. The Dokploy host **never compiles anything** — it only pulls images from GHCR and runs a compose file kept in this repo under `deploy/`.

Target: a private WotLK 3.3.5a server for a small friend group. Reliability and zero-touch updates matter more than features.

## Architecture (decided — build on it, don't re-litigate)

- **Build:** GitHub Actions on push to `master` runs the repo's own Docker build (`docker compose build`, respecting `DOCKER_IMAGE_TAG`) with submodules checked out, then pushes `ghcr.io/<github-user>/ac-wotlk-{authserver,worldserver,db-import,client-data}` tagged `latest` and `sha-<short>`. Public fork, so runner minutes are free; ~1 h per build is acceptable. A red build means nothing ships — CI is the safety gate for module/upstream breakage.
- **Run:** Dokploy Compose service, Git source = this repo, compose path = `deploy/docker-compose.yml`, mode = docker-compose (not Stack). The deployed compose has `image:` only, no `build:`. All AC services carry `pull_policy: always` so every Dokploy deploy fetches the newest `latest`; only containers whose image changed get recreated, the DB stays up.
- **Deploy trigger:** pull-based. GitHub cannot reach the home Dokploy (inbound tunnel is geoblocked), so no webhooks. A nightly job at 05:00 Europe/Bratislava on the Dokploy CT triggers a redeploy via Dokploy's local API (verify endpoint/params in the Dokploy API docs; fallback is a plain cron running `docker compose pull && docker compose up -d` against Dokploy's compose path). This is also the maintenance window.
- **Config:** everything via environment variables set in Dokploy's Environment tab. AzerothCore reads any `.conf` key from an `AC_`-prefixed env var, keys auto-derived from the conf key (`AllowTwoSide.Interaction.Calendar` → `AC_ALLOW_TWO_SIDE_INTERACTION_CALENDAR`, `GM.InGMList.Level` → `AC_GM_IN_GMLIST_LEVEL`). No hand-edited `.conf` files inside volumes.
- **Networking:** compose publishes TCP 3724 (auth) and 8085 (world) on the CT's LAN IP; the router forwards those. Dokploy Domains/Traefik unused — WoW is raw TCP. SOAP (7878) may be published on LAN only, never forwarded.
- **Realmlist:** `acore_auth.realmlist` gets `address` = public host/IP, `localAddress` = CT LAN IP, `localSubnetMask` = LAN mask, all from env, applied by a one-shot init service (see Task 3).
- **Backups:** Proxmox Backup Server snapshots the whole CT. On top: cron `mysqldump` of `acore_characters` and `acore_auth` to a host path, keep N days.

## Modules

| Path | Source | Why |
|---|---|---|
| `modules/mod-autobalance` | `azerothcore/mod-autobalance` | scales dungeons/raids to group size — required |

Add rows as decided. Every module is a submodule pinned to a commit. Bump pins deliberately, one at a time; CI is the gate.

## Tasks — in order, each green before the next

**Status (2026-08-29):** 1–7 are implemented — `.gitmodules`, `.github/workflows/{build-images,upstream-sync}.yml` and `deploy/`. What is left is the manual half, all of it in `deploy/RUNBOOK.md`: enable Actions in the fork, get one green `build-images` run, set the four GHCR packages public, create the Dokploy service, add the router forwards, install the two cron lines.

1. **Submodules.** Add `mod-autobalance` under `modules/` pinned to a current commit. `git submodule update --init --recursive` must work from a clean clone.

2. **CI → GHCR.** Upstream ships workflows that build and push the Docker images (look in `.github/workflows/` for the Docker build/push job and reuse its build steps). Create our own workflow file (`.github/workflows/build-images.yml`) that: checks out with `submodules: recursive`; logs into `ghcr.io` with `GITHUB_TOKEN` (`permissions: packages: write`); builds via the repo's compose/Dockerfile targets; retags and pushes the four images with `latest` and `sha-<short>`. Leave upstream workflow files untouched — disable the ones that would fail in a fork from the Actions UI, so upstream sync stays conflict-free. Done = one green run and four packages visible on GitHub, set to public visibility (so the home host pulls without credentials). Get it green first; optimize caching (BuildKit GHA cache, ccache if the Dockerfile supports it) only if runs exceed ~90 min.

3. **Deploy compose.** Write `deploy/docker-compose.yml`, derived from the repo's compose but: `image:` only, GHCR names, `pull_policy: always`, `restart: unless-stopped`, ports from `${DOCKER_*_EXTERNAL_PORT}` env, named volumes, `stdin_open`/`tty` on worldserver, `container_name: ac-worldserver` (Dokploy prefixes the project name otherwise, and the runbook relies on `docker attach ac-worldserver`). Keep the `ac-db-import` and `ac-client-data-init` one-shots exactly as upstream does them — check whether client data is downloaded into a volume at first start or baked into the image, and keep that behaviour. Add `ac-realmlist-init`: a `mysql:8` client container that runs after `ac-db-import` (`condition: service_completed_successfully`) and executes an idempotent `UPDATE acore_auth.realmlist SET address=..., localAddress=..., localSubnetMask=...` from `REALM_ADDRESS`, `REALM_LOCAL_ADDRESS`, `REALM_LOCAL_SUBNET_MASK`. The file must come up with a plain `docker compose up -d` — no profiles required.

4. **Env template.** `deploy/.env.example` documenting every variable Dokploy needs: `DOCKER_DB_ROOT_PASSWORD`, `DOCKER_*_EXTERNAL_PORT` (default the DB port to something other than 3306 or don't publish it — the CT runs other services), `REALM_*`, and the `AC_*` overrides we run (cross-faction interaction keys, rates, `AC_SOAP_ENABLED`) plus `AutoBalance.*` settings. Values marked `TBD` are decisions for the human, not for you.

5. **Ops scripts.** `deploy/redeploy.sh` (nightly trigger, see Deploy trigger above) and `deploy/backup.sh` (`docker compose exec ac-database mysqldump …` for the two DBs into a host path, rotate). Document the two cron lines in the runbook.

6. **Upstream sync.** Scheduled weekly workflow that merges `upstream/master` into `master` and pushes. A red image build afterwards is the signal to look; it is not a reason to skip syncing. Our footprint outside `deploy/`, `modules/`, `.gitmodules`, `CLAUDE.md` and our own workflow files must stay near zero so merges are clean.

7. **Runbook.** `deploy/RUNBOOK.md` with the steps that stay manual: enabling Actions in the fork; router port forwards; Dokploy service creation (Git source, compose path, env); first-time `docker attach ac-worldserver` → `account create <user> <pass>` → `account set gmlevel <user> 3 -1` → detach with Ctrl-P Ctrl-Q; client setup (unmodified 3.3.5a `Wow.exe`, remove any third-party `patch-*.MPQ` under `Data/`, set `Data/enUS/realmlist.wtf`); rollback (pin a `sha-` tag in the compose and redeploy).

## Constraints

- Never modify core source under `src/`. Customization is modules, compose, env, workflows. If something genuinely needs a core change, stop and say so.
- Never add `build:` to `deploy/docker-compose.yml`.
- Never bake client data (maps/vmaps/mmaps/DBC) into images we publish.
- Never commit secrets. `deploy/.env` is gitignored; only `.env.example` is tracked.
- Keep names stable: service, container and volume names in `deploy/` are relied on by scripts and the runbook.
- Prefer new files over edits to upstream files.

## Verify, don't assume

- Exact upstream workflow names, Dockerfile targets, and image names.
- Whether upstream's compose uses profiles (`COMPOSE_PROFILES`) and which env var names it uses for external ports and the DB password.
- How client-data initialization works in the current tree.
- The Dokploy API call for triggering a compose deploy, and whether the installed Dokploy version has a Schedules feature that could replace the cron.
- GitHub-hosted runner build time before adding cache complexity.

## Environment facts

- Home host: Proxmox VE. Dokploy runs in an LXC there with the rest of the Docker services. Router: UniFi (port forwards). Backups: PBS.
- Client: WotLK 3.3.5a enUS.
- Timezone for schedules: Europe/Bratislava.
- The human is a web developer and experienced homelab admin — be direct, skip beginner explanations, show the diff and the reasoning.

## Upstream's own agent docs

Only relevant when touching core source, which we don't: @AGENTS.md
