# Runbook — AzerothCore friends server

Everything in this file is manual. The automated parts (image builds, upstream
sync, nightly redeploy, backups) are described only where you have to wire them
up once.

**Shape of the system**

| Where | What |
|---|---|
| GitHub Actions (public fork) | builds four images on every push to `master`, tagged `latest` + `sha-<short>` |
| GHCR | `ghcr.io/<owner>/ac-wotlk-{authserver,worldserver,db-import,client-data}` |
| Dokploy LXC on Proxmox | pulls those images and runs `deploy/docker-compose.yml`. Compiles nothing. |
| Cron on the LXC | 04:30 backup, 05:00 redeploy (Europe/Bratislava) |

---

## 1. One-time: the GitHub fork

1. **Enable Actions.** Actions tab → *I understand my workflows, go ahead and
   enable them*. Forks ship with Actions disabled.

2. **Silence upstream's workflows.** Every upstream workflow job is already
   guarded by `github.repository == 'azerothcore/azerothcore-wotlk'`, so in this
   fork they all skip — except **`add-to-project.yml`**, which has no such guard
   and fails on every issue for want of a project token. Disable at least that
   one: Actions → *add-to-project* → `⋯` → **Disable workflow**. Disable the rest
   the same way if the skipped runs are noise. Do this from the UI, never by
   editing the files — that keeps upstream merges conflict-free.

3. **First build.** Push to `master`, or Actions → *build-images* → **Run
   workflow**. Expect roughly an hour. Green means four packages appear under
   the account's Packages.

4. **Make the packages public.** Each package → *Package settings* → *Danger
   Zone* → **Change visibility → Public**. Without this the Dokploy host needs a
   GHCR credential; with it, `docker pull` works anonymously. Repeat for all
   four: `ac-wotlk-authserver`, `ac-wotlk-worldserver`, `ac-wotlk-db-import`,
   `ac-wotlk-client-data`.

5. If the build fails at the GHCR push with a 403, check Settings → Actions →
   General → *Workflow permissions* and set **Read and write permissions**.

---

## 2. One-time: the router (UniFi)

Forward to the LXC's LAN IP:

| Port | Proto | Purpose |
|---|---|---|
| 3724 | TCP | authserver |
| 8085 | TCP | worldserver |

**Do not forward 7878 (SOAP) or the MySQL port.** SOAP is bound to loopback by
default (`DOCKER_SOAP_BIND_IP`), MySQL to loopback on port 13306.

---

## 3. One-time: the Dokploy service

1. Project → **Create Service → Compose**.
2. *Provider*: **Git**. Repository: this fork. Branch: `master`.
3. *Compose Path*: `deploy/docker-compose.yml`.
4. *Compose Type*: **Docker Compose** — not Stack. Stack mode is Swarm, and
   this file uses `depends_on: condition:` which Swarm ignores.
5. *Environment*: paste a filled-in copy of [`.env.example`](.env.example).
   Everything marked `TBD` is a decision:
   - `DOCKER_DB_ROOT_PASSWORD` — generate one, store it in your password manager.
   - `REALM_ADDRESS` — the public IP or DNS name friends type into
     `realmlist.wtf`.
   - `REALM_LOCAL_ADDRESS` / `REALM_LOCAL_SUBNET_MASK` — the LXC's LAN IP and
     the LAN netmask, so clients on the LAN skip the router hairpin.
   Do **not** put `DOKPLOY_*` or `BACKUP_*` here; those belong to the ops
   scripts on the host and would otherwise end up inside every container.
6. **Deploy.**

### What the first deploy does

`ac-database` comes up → `ac-db-import` creates the three databases and applies
every SQL update (this takes a few minutes on an empty DB) → `ac-realmlist-init`
writes the realm addresses → `ac-client-data-init` downloads maps, vmaps, mmaps
and DBC into the `ac-client-data` volume (several GB, expect 10–20 minutes on
the first run only) → `ac-authserver` and `ac-worldserver` start.

Client data is **downloaded into a volume**, never baked into our images.
Subsequent deploys re-run the one-shots; they exit immediately once the data is
already present and the DB is current.

---

## 4. One-time: the first GM account

The worldserver console is attachable because the service sets
`stdin_open`/`tty` and pins `container_name: ac-worldserver`.

```console
$ docker attach ac-worldserver
account create <user> <pass>
account set gmlevel <user> 3 -1
```

Detach with **Ctrl-P Ctrl-Q**. Pressing Ctrl-C instead stops the worldserver.

`3` is GM level (`SEC_ADMINISTRATOR`), `-1` means all realms. Account names and
passwords are case-insensitive and capped at 17 characters.

---

## 5. One-time: cron on the Dokploy LXC

Put the ops-only variables in `/etc/azerothcore/ops.env` (root-owned, `chmod
600`) — the commented block at the bottom of `.env.example` lists them:

```sh
DOCKER_DB_ROOT_PASSWORD=...        # same value as in Dokploy
DOKPLOY_URL=http://localhost:3000
DOKPLOY_API_KEY=...                # Dokploy → profile → API/CLI → generate
DOKPLOY_COMPOSE_ID=...             # from the compose service's URL
BACKUP_DIR=/var/backups/azerothcore
BACKUP_KEEP_DAYS=14
```

Then two lines in root's crontab (`crontab -e`):

```cron
30 4 * * * TZ=Europe/Bratislava /path/to/repo/deploy/backup.sh   >> /var/log/ac-backup.log 2>&1
0  5 * * * TZ=Europe/Bratislava /path/to/repo/deploy/redeploy.sh >> /var/log/ac-redeploy.log 2>&1
```

Backup runs first so the newest dump predates whatever a new image might break.
05:00 is also the maintenance window: the redeploy recreates only the containers
whose image changed, so the database stays up, but players are disconnected
while the worldserver restarts.

**Alternative to host cron:** Dokploy 0.22+ has a *Schedules* tab on the compose
service that runs a cron'd command against the stack, with per-run logs in the
UI. If the installed version has it, prefer it for the backup job — the logs are
easier to find than `/var/log`. Point it at the same scripts.

**`redeploy.sh` modes.** With `DOKPLOY_API_KEY` + `DOKPLOY_COMPOSE_ID` it POSTs
to Dokploy's local API (`compose.redeploy`, falling back to `compose.deploy` on
older builds, both `{"composeId": "..."}` with an `x-api-key` header). Confirm
the endpoint against your installed version's API docs at
`http://<dokploy>:3000/swagger`; if it has moved, set only `AC_COMPOSE_FILE` and
the script falls back to a plain `docker compose pull && up -d` against
Dokploy's checkout, which is equivalent for our purposes.

**`backup.sh`** dumps `acore_characters` and `acore_auth` only — `acore_world`
is rebuilt from the repo by `ac-db-import` on every deploy. It reaches the
database through `docker exec ac-database` (the pinned container name, stable
regardless of the project name Dokploy assigns); set `AC_COMPOSE_FILE` to use
`docker compose exec` instead. This sits on top of the PBS snapshots of the
whole CT — it exists so one bad update can be undone without rolling the CT
back.

Restore a dump:

```console
$ gunzip -c /var/backups/azerothcore/acore_characters-20260829-043000.sql.gz \
  | docker exec -i -e MYSQL_PWD="$DOCKER_DB_ROOT_PASSWORD" ac-database \
      mysql --user=root acore_characters
```

---

## 6. Client setup (each player)

1. An **unmodified 3.3.5a (12340) enUS client**.
2. Delete any third-party `patch-*.MPQ` from `Data/` and `Data/enUS/`. The
   original `patch.MPQ`, `patch-2.MPQ`, `patch-3.MPQ` and `patch-enUS-*.MPQ`
   that ship with the client stay.
3. Edit `Data/enUS/realmlist.wtf` to a single line:
   ```
   set realmlist <REALM_ADDRESS>
   ```
4. Launch `Wow.exe` directly — not `Launcher.exe`, which will try to patch the
   client back to retail.

If the realm list is empty at the character screen, the client reached the
authserver but the realm is flagged offline — check that `ac-worldserver` is up.

---

## 7. Rollback

Every build also publishes an immutable `sha-<short>` tag; the run summary of
*build-images* prints the exact one.

1. Dokploy → Environment → set `AC_IMAGE_TAG=sha-abc1234`.
2. Redeploy.

Because `AC_IMAGE_TAG` is applied to all four images at once, the world DB
schema and the binaries always move together. Set it back to `latest` once the
underlying problem is fixed on `master`.

Rolling back does **not** undo SQL migrations already applied to the character
or auth databases — for that, restore a dump (§5).

---

## 8. Upstream sync

`upstream-sync.yml` merges `azerothcore/azerothcore-wotlk` `master` into ours
every Monday 01:00 UTC and then triggers *build-images* explicitly (a push made
with `GITHUB_TOKEN` does not trigger workflows on its own).

- **Merge conflict** → the job fails with the commands to resolve locally. Our
  footprint outside `deploy/`, `modules/`, `.gitmodules`, `CLAUDE.md`,
  `.gitignore` and our own two workflow files is deliberately nil, so this
  should be rare.
- **Red build afterwards** → look at it; it is upstream or a module pin
  breaking. It is not a reason to stop syncing. The running server is
  unaffected: `latest` still points at the last green build, and the nightly
  redeploy pulls that same image.

Module pins are bumped deliberately, one at a time:

```console
$ git -C modules/mod-autobalance fetch origin && git -C modules/mod-autobalance checkout <commit>
$ git add modules/mod-autobalance && git commit -m "chore(modules): bump mod-autobalance"
```

---

## 9. Checks and gotchas

**Is it up?**

```console
$ docker compose ps                      # or the Dokploy UI
$ docker logs --tail 50 ac-worldserver
$ docker exec ac-database mysql -uroot -p"$DOCKER_DB_ROOT_PASSWORD" \
    -e "SELECT id,name,address,localAddress,port FROM acore_auth.realmlist;"
```

**Expected at worldserver startup:** an ERROR line reading
`> Config::LoadFile: Failed open file
'/azerothcore/env/dist/etc/modules/AutoBalance.conf'`. That file is
intentionally absent — module settings come from the `AC_AUTO_BALANCE_*`
environment variables on top of the module's built-in defaults, exactly as
intended. Only `AutoBalance.conf.dist` is installed by the build, and nothing
copies it into place; a missing *module* config is logged, never fatal.

**`ac-realmlist-init` exited 1** with `acore_auth.realmlist has no row with
id=N`: `AC_REALM_ID` points at a realm row that does not exist. The base auth
DB ships exactly one row, `id=1`. Either set `AC_REALM_ID=1` or insert the row
you meant. The one-shot refuses to write rather than leave the realm
advertising `127.0.0.1`, and `ac-authserver` waits on it, so the stack stays
down until it is fixed.

**Config in general:** every `.conf` key can be set from an `AC_`-prefixed
environment variable; the name is the key upper-snake-cased, with dots and
camelCase boundaries becoming underscores
(`AllowTwoSide.Interaction.Calendar` → `AC_ALLOW_TWO_SIDE_INTERACTION_CALENDAR`,
`GM.InGMList.Level` → `AC_GM_IN_GMLIST_LEVEL`). Never hand-edit a `.conf` inside
the `ac-etc` volume; add the variable to `deploy/docker-compose.yml` and
`.env.example` instead so the setting survives a volume rebuild.

**Changing the world port** also changes what the authserver advertises:
`ac-realmlist-init` writes `DOCKER_WORLD_EXTERNAL_PORT` into `realmlist.port`.
Change it in one place only.

**Volumes** (`docker volume ls`): `ac-database` (the only irreplaceable one
besides your dumps), `ac-client-data` (re-downloadable, several GB), `ac-etc`,
`ac-logs`. Deleting `ac-etc` is safe — the entrypoint repopulates it from the
image on next start.
