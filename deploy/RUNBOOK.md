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

2. **Silence the core's workflows.** Most jobs in the Playerbot fork are guarded
   by `github.repository == 'mod-playerbots/azerothcore-wotlk'` and skip here,
   but **five have no guard at all** and fire on every push to our master:
   `core-build.yml`, `core-build-playerbots.yml`, `macos_build.yml`,
   `windows_build.yml` (each a full matrix compile) and `add-to-project.yml`
   (fails on every issue for want of a project token). Disable all five:
   Actions → the workflow → `⋯` → **Disable workflow**. They cost nothing on a
   public repo but they bury the one run that matters. Do this from the UI,
   never by editing the files — that keeps upstream merges conflict-free.

3. **First build.** Push to `master`, or Actions → *build-images* → **Run
   workflow**. The first green run took 21 minutes on a stock `ubuntu-latest`
   runner (no cache), so the ~1 h budget has room. Green means four packages
   appear under the account's Packages.

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

Everything below was checked against Dokploy's own source (v0.30.2). The
defaults matter more than usual here: a couple of the toggles rewrite the
compose file before it is deployed, changing resource names and the network
layout this runbook and `backup.sh` depend on.

### 3.1 Before you start

The LXC must be able to `docker pull` the four images. Either make the packages
public (§1.4), or keep them private and `docker login ghcr.io` **as root** on
the CT — Dokploy writes `DOCKER_CONFIG=/root/.docker` into the environment it
deploys with, so root's credentials are the ones compose will use. Public is one
less thing to rotate.

### 3.2 Create the service

Project → **Create Service → Compose**.

| Field | Value | Why |
|---|---|---|
| Name | `azerothcore` | becomes `appName`: the compose project name, the volume prefix, and the checkout path `/etc/dokploy/compose/azerothcore/code` |
| Provider | **Git** | Dokploy re-clones on every deploy |
| Repository / Branch | this fork / `master` | `master` is what CI builds images from |
| Compose Path | `deploy/docker-compose.yml` | relative to the repo root |
| Compose Type | **Docker Compose** | Stack is Swarm: it ignores `depends_on: condition:`, so the one-shots would race the servers |

Leave these **off** — all of them are off by default:

- **Isolated Deployment** — rewrites the compose file to add an external network
  named after the app to every service, creates it, and connects Traefik to it.
  We already define `ac-network`, and Traefik has no business in a raw-TCP
  stack. Its companion toggle suffixes every named volume, which would orphan
  the database if it were ever flipped after the first deploy.
- **Randomize / name suffix** — appends a `COMPOSE_PREFIX` suffix to resource
  names. Nothing here collides; keeping names literal is what makes
  `docker attach ac-worldserver` work.
- **Enable Submodules** — `deploy/docker-compose.yml` needs nothing from
  `modules/`; the module code is already baked into the images. Off keeps the
  clone small.
- **Auto Deploy / webhook** — GitHub cannot reach this host (§5 does the
  pulling instead).

### 3.3 Environment

Paste a filled-in copy of [`.env.example`](.env.example) into the Environment
tab. What Dokploy does with it: writes
`/etc/dokploy/compose/<appName>/code/deploy/.env`, prepending `APP_NAME`,
`COMPOSE_PROJECT_NAME=<appName>` and `DOCKER_CONFIG=/root/.docker`. Compose then
interpolates every `${...}` in our file from it.

Those variables are **not** injected into the containers automatically — only
the keys listed under a service's `environment:` in
`deploy/docker-compose.yml` reach the server. Adding `AC_SOMETHING` in Dokploy
alone does nothing; add it to the compose file too.

The four decisions marked `TBD`:

- `DOCKER_DB_ROOT_PASSWORD` — generate one, store it in your password manager,
  and put the same value in `/etc/azerothcore/ops.env` for `backup.sh` (§5).
- `REALM_ADDRESS` — the public IP or DNS name friends put in `realmlist.wtf`.
- `REALM_LOCAL_ADDRESS` — the LXC's LAN IP, so LAN clients skip the router
  hairpin.
- `REALM_LOCAL_SUBNET_MASK` — the LAN netmask (`255.255.255.0` for a /24).

Do **not** put `DOKPLOY_*` or `BACKUP_*` here; they belong to the ops scripts on
the host, and anything in this tab is one `env_file:` away from every container.

### 3.4 What Dokploy actually runs

```sh
cd /etc/dokploy/compose/<appName>/code
docker compose -p <appName> -f ./deploy/docker-compose.yml up -d --build --remove-orphans
```

- `--build` is Dokploy's, not ours, and is a no-op because no service in
  `deploy/docker-compose.yml` has a `build:` section. Keep it that way — adding
  one would make the LXC compile AzerothCore.
- `-p <appName>` prefixes **volumes** (`azerothcore_ac-database`, …) but not our
  containers: those are pinned with `container_name`, which is why
  `docker attach ac-worldserver` and `backup.sh` work regardless of the project
  name.

**Version trap, worth knowing before you upgrade Dokploy.** The command above is
what every release up to v0.30.2 runs. Dokploy's `canary` branch adds
`--project-directory <code>` to it. Compose reads the `.env` file from the
project directory, so with that flag it looks in `code/.env` while Dokploy still
writes `code/deploy/.env` — every variable goes unset. The failure is immediate
and loud, at deploy time:

```
error while interpolating services.ac-database.environment.MYSQL_ROOT_PASSWORD:
required variable DOCKER_DB_ROOT_PASSWORD is missing a value
```

Fix without moving the file: put this in the service's **Command** field, which
replaces the generated command (Dokploy prefixes it with `docker` and rejects
shell metacharacters, so keep it to plain flags):

```
compose -f ./deploy/docker-compose.yml --env-file ./deploy/.env up -d --remove-orphans
```

The project name still comes from `COMPOSE_PROJECT_NAME` inside that env file,
so nothing else changes.

### 3.5 Deploy

Hit **Deploy**. The first one does, in order:

`ac-database` starts and passes its healthcheck → `ac-db-import` creates the
three databases and applies every SQL update (a few minutes on an empty DB) →
`ac-realmlist-init` writes the realm addresses → `ac-client-data-init` downloads
maps, vmaps, mmaps and DBC into the `ac-client-data` volume (several GB, 10–20
minutes, first run only) → `ac-authserver` and `ac-worldserver` start.

Client data is **downloaded into a volume**, never baked into our images.
Later deploys re-run the one-shots; they exit in seconds once the data is
present and the DB is current.

### 3.6 Verify

```console
$ docker ps --filter name=ac- --format 'table {{.Names}}\t{{.Status}}'
$ docker logs --tail 30 ac-db-import          # "Database is up to date"
$ docker logs --tail 5  ac-realmlist-init     # the addresses it wrote
$ docker exec -e MYSQL_PWD="$DOCKER_DB_ROOT_PASSWORD" ac-database \
    mysql -uroot -e "SELECT id,name,address,localAddress,port FROM acore_auth.realmlist;"
$ docker volume ls | grep ac-             # <appName>_ac-{database,client-data,etc,logs}
$ ss -lntp | grep -E '3724|8085'          # published on the CT
```

### 3.7 The composeId for `redeploy.sh`

Open the service and read the last segment of the URL:

```
/dashboard/project/<projectId>/environment/<environmentId>/services/compose/<composeId>
```

Or ask the API, once you have a key (§5):

```console
$ curl -s -X POST http://localhost:3000/api/project.all -H "x-api-key: $DOKPLOY_API_KEY" \
  | jq -r '.. | objects | select(.composeId?) | "\(.name) \(.composeId)"'
```

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

**Alternative to host cron:** Dokploy 0.22+ has *Schedule Jobs*, with per-run
logs in the UI instead of `/var/log`. Four job types exist; the one that fits
both scripts is **Server** (runs a script on the host), not **Compose** (which
runs a command *inside* a service container and needs that container up). If you
use it, keep `COMPOSE_PROJECT_NAME` untouched — Dokploy identifies the project by
it.

**`redeploy.sh` modes.** With `DOKPLOY_API_KEY` + `DOKPLOY_COMPOSE_ID` it POSTs
to Dokploy's local API: `POST /api/compose.redeploy`, body `{"composeId": "..."}`,
`x-api-key` header — as documented for v0.30.2, with `compose.deploy` as the
fallback for older builds. The key comes from *Settings → Profile → API/CLI*.
Your instance's own spec is at `http://<dokploy>:3000/api/openapi.json` if you
want to diff it. If the endpoint ever moves, set only `AC_COMPOSE_FILE`
(`/etc/dokploy/compose/<appName>/code/deploy/docker-compose.yml`) and the script
falls back to a plain `docker compose pull && up -d` against Dokploy's own
checkout, which is equivalent for our purposes.

**`backup.sh`** dumps `acore_characters`, `acore_auth` and `acore_playerbots`
— `acore_world` is rebuilt from the repo by `ac-db-import` on every deploy. It reaches the
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

`upstream-sync.yml` merges `mod-playerbots/azerothcore-wotlk` branch
`Playerbot` into ours every Monday 01:00 UTC and then triggers *build-images*
explicitly (a push made with `GITHUB_TOKEN` does not trigger workflows on its
own). That fork merges AzerothCore master on its own schedule, so upstream AC
fixes reach us one hop later than they used to — the price of playerbots.

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

**Volumes** (`docker volume ls`) are prefixed with the compose project name, so
they read `<appName>_ac-database` (the only irreplaceable one besides your
dumps), `<appName>_ac-client-data` (re-downloadable, several GB),
`<appName>_ac-etc` and `<appName>_ac-logs`. Renaming the Dokploy service changes
`appName` and therefore orphans all four — the DB included. Deleting the `ac-etc`
volume is safe: the entrypoint repopulates it from the image on next start.

---

## 10. Bots and modules

### What the core swap changed

`master` tracks `mod-playerbots/azerothcore-wotlk` (branch `Playerbot`) instead
of AzerothCore proper, because `mod-playerbots` does not build against upstream.
Everything else is untouched: same Dockerfile targets, same four images, same
compose, same Dokploy service. We still never edit `src/` ourselves — the
patches live in the core we track.

One structural change: **playerbots keeps a fourth database**,
`acore_playerbots`. `ac-db-import` creates and migrates it because the compose
passes `AC_UPDATES_ENABLE_DATABASES=15` (bit 8 = playerbots); the shipped
default of 7 would silently leave it out and the worldserver would fail to
start. `backup.sh` dumps it along with characters and auth.

Expect the first deploy after the swap to be slow twice over: `ac-db-import`
has a fourth database to build, and the worldserver generates the random bot
accounts and characters on first start.

### Sizing the box

The module's own guidance, for reference, is written for far bigger servers
than ours: minimum **16 GB RAM** (it notes 11-12 GB once all map grids are
loaded) and **4 cores at 3 GHz**, preferring 32 GB and 6+ faster cores.

The number that surprises people is that memory tracks **loaded map grids**
more than bot count. Bots roaming the whole world pull most of Azeroth into
memory whether there are 300 of them or 1000, so the jump from 40 to 300 costs
much less than 7x. Rough targets for this stack, worldserver plus MySQL,
before whatever else the CT runs:

| Bots | Plan for | Notes |
|---|---|---|
| 40-100 | ~6 GB, 2-4 cores | grids stay partly loaded; barely noticeable population |
| 300 | ~10-12 GB, 4 cores | most of the world resident; LFG and BGs actually pop |
| 500+ | 16 GB+, 6 cores | the module's own baseline |

Measured on this CT (6 cores, 32 GB, sharing with the other Docker services):
**300 bots idle at 40% of 6 cores and 8.2 GB total**. Most of that memory is
map grids, which are already resident at 300, so the step to 1000 costs session
and AI state rather than another copy of the world.

Our settings are sized for that box: 1000 bots, `AC_MAP_UPDATE_THREADS=5` (of
6 cores, leaving one for MySQL and the rest of the CT), `DOCKER_DB_BUFFER_POOL=4G`.
On a smaller machine, scale all three down together.

CPU shortage does **not** show up as lag for players: `botActiveAloneSmartScale`
reduces how many bots are actively simulated to hold the world diff inside its
band, so an undersized CT gives you duller bots rather than a stuttering realm.
Memory shortage is the one that bites — the worldserver gets OOM-killed.

Verify with `server info` on the worldserver console (or `.server info` in
game): the module's threshold is latency under 70-80 ms with percentiles
around 100-150. Above that, drop the bot count or set
`AC_AI_PLAYERBOT_BOT_ACTIVE_ALONE=10` explicitly.

Three settings in `deploy/` exist for this and are worth revisiting when the CT
changes: `AC_MAP_UPDATE_THREADS` (stock AzerothCore ships **1**),
`DOCKER_DB_BUFFER_POOL` (the mysql image ships **128M**), and the bot count
itself.

### Why there is an ac-playerbots-sql one-shot

mod-playerbots creates and migrates `acore_playerbots` from inside the
**worldserver**, not from `ac-db-import` — `dbimport`'s `Main.cpp` only ever
adds the Login, Character and World pools, so no update mask can make it do
this. The module reads its SQL from the source tree at
`/azerothcore/modules/mod-playerbots/data/sql`, and the worldserver image ships
only the binary. Without help it aborts at startup:

```
Database Playerbots is empty, auto populating it...
>> Directory "/azerothcore/modules/mod-playerbots/data/sql/playerbots/base/" not exist
Could not populate the Playerbots database, see log for details.
```

The `ac-playerbots-sql` one-shot copies the module sources out of the db-import
image (which does carry them) into a volume the worldserver mounts read-only at
that path. It re-runs on every deploy, so the SQL always matches the pinned
module commit. If you ever see that error again, check whether that one-shot
exited 0 — `docker logs ac-playerbots-sql` prints how many files it staged.

### Tuning the bots

All of it is `AC_*` env in Dokploy — the module's `.conf` is not installed, so
these override its *compiled* defaults, which are **500 random bots**. Ours:

| Variable | Ours | Meaning |
|---|---|---|
| `AC_AI_PLAYERBOT_MIN_RANDOM_BOTS` / `MAX` | 40 | population of the world. Each bot is a player session — raise while watching RAM |
| `AC_AI_PLAYERBOT_DISABLED_WITHOUT_REAL_PLAYER` | 1 | bots idle when nobody is online; set 0 for a world that lives 24/7 |
| `AC_AI_PLAYERBOT_SELF_BOT_LEVEL` | 2 | 0 off, 1 GM only, 2 all players, 3 on login — 2 lets everyone drive their own alts |
| `AC_AI_PLAYERBOT_RANDOM_BOT_MIN_LEVEL` / `MAX` | 1 / 80 | level spread of the random population |

In game, bots answer to `.bot` (a player-level command, in-game only):
`.bot add <name>`, `.bot remove <name>`, `.bot init=<level>`. The
[wiki](https://github.com/mod-playerbots/mod-playerbots/wiki) covers strategies
and the client addons that give it a UI.

### mod-ah-bot: the one module with a manual step

It posts auctions *as a character*, so it needs an account of its own. Both
halves are off in code until you give it an account id:

```console
$ docker attach ac-worldserver
account create ahbot <password>
```

Log in on that account, create one character per faction, log out. Then:

```console
$ docker exec -e MYSQL_PWD="$DOCKER_DB_ROOT_PASSWORD" ac-database \
    mysql -uroot -e "SELECT id FROM acore_auth.account WHERE username='AHBOT';"
```

Put that id in `AC_AUCTION_HOUSE_BOT_ACCOUNT`, set
`AC_AUCTION_HOUSE_BOT_ENABLE_SELLER=1` and `..._ENABLE_BUYER=1`, redeploy.
Until the id is non-zero the module logs `AHBot: Account id and player id
missing from configuration` and does nothing. Don't play on that character —
browsing the AH with it hangs on "Searching for items...".

`mod-transmog` and `mod-solo-lfg` need nothing: their compiled defaults are
already on.

### Trying a change before it becomes `latest`

*build-images* publishes `latest` only from `master`. Run it by hand on any
branch (Actions → *build-images* → **Run workflow** → pick the branch) and it
publishes just that branch's `sha-` tag. Pin that tag in Dokploy
(`AC_IMAGE_TAG=sha-abc1234`), redeploy, and you are playing the branch while
`latest` — and therefore the nightly redeploy — still points at the last green
master build. Merge to master when you like it, set `AC_IMAGE_TAG` back to
`latest`.

### Adding another module later

One commit each, and CI is the gate:

```console
$ git submodule add https://github.com/<owner>/<mod-name> modules/<mod-name>
$ printf '!/modules/<mod-name>\n' >> .gitignore   # modules/* is ignored by default
$ git add .gitmodules .gitignore modules/<mod-name> && git commit
```

Push, wait for *build-images* to go green, redeploy. Its SQL is applied
automatically (`Updates.AllowedModules = "all"`), and its settings come from
`AC_*` env vars — the name is the conf key upper-snake-cased. Always check the
module's **compiled** defaults (`GetOption<...>("Key", <default>)` in its
source), not just its `.conf.dist`: our images install neither, and the two
disagree more often than you would like — playerbots ships 500 bots in code.
