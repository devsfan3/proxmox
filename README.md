# proxmox

Scripts for building and looking after Proxmox VE containers, in the style of
the community helper scripts: run one line on the Proxmox host and get the job
done.

Some of these build a container and can update it later; others work across the
containers you already have. Read a script before running it — everything below
runs as root on your hypervisor.

## unifi-analyzer-lxc.sh

Creates an unprivileged Debian LXC and installs the [UniFi Support File
Analyzer](https://github.com/Inch-high/unifi-support-file-analyzer) into it: a
local web app that reads a UniFi support file and explains what is in it —
restart causes, processor history, what is running, what the devices behind the
gateway were talking to, and what personal data the file would carry if you
sent it to support.

The analyzer's code comes from the upstream project on every install and
update. This repository holds only the container script.

### Install

On the Proxmox VE host, as root:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/devsfan3/proxmox/main/unifi-analyzer-lxc.sh)"
```

It picks the next free container ID, the newest Debian template on offer, and
the first storage that will hold a root disk. When it finishes it prints the
address to open.

| | Default |
| --- | --- |
| Container | unprivileged Debian, `onboot` |
| Resources | 4 cores, 4096 MB RAM, 512 MB swap, 16 GB disk |
| Network | `vmbr1`, DHCP |
| Port | 8077 |

Override any of it from the environment, or pass `--advanced` to be asked:

```bash
CTID=210 CT_HOSTNAME=ufa BRIDGE=vmbr0 CORES=8 MEMORY=8192 \
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/devsfan3/proxmox/main/unifi-analyzer-lxc.sh)"
```

Settings: `CTID`, `CT_HOSTNAME`, `STORAGE`, `TEMPLATE_STORAGE`, `TEMPLATE`,
`CORES`, `MEMORY`, `SWAP`, `DISK`, `BRIDGE`, `VLAN`, `NET` (`dhcp` or a CIDR),
`GATEWAY`, `PORT`, `UNPRIVILEGED`.

### Update

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/devsfan3/proxmox/main/unifi-analyzer-lxc.sh)" -- --update
```

Flags go after the `--`. It finds the container it built, pulls the latest analyzer, reinstalls its
dependencies and restarts the service. It says so and stops if there is nothing
to update; `--force` reinstalls anyway. Add a container ID (`--update 210`) if
you have more than one.

Dependencies are installed before the service is restarted, so a failed update
leaves the running service alone rather than restarting it onto a half-updated
environment.

Two other ways to the same thing: run the script *inside* the container and it
updates that container, or run `unifi-analyzer-update` in there directly.

### Worth knowing before you use it

**There is no login.** The analyzer answers on every address in the container,
because a container reached from elsewhere has to. Anyone on your network who
knows the address can open it, and what it shows is your network's addresses,
your device names, and in its Privacy tab your secrets. Put it on a network you
trust, or put something in front of it that asks for a password.

**Extracted data is wiped on every service start**, including a reboot of the
container — a support file has no reason to outlive the session that needed it.
This mirrors the upstream project's own default. To keep it instead, comment
out the `ExecStartPre` line in `/etc/systemd/system/unifi-analyzer.service` and
`systemctl daemon-reload`.

If the install fails part way, the script destroys the container it was
building rather than leaving a broken one behind.

### Afterwards

```bash
pct enter <CTID>                     # a shell in the container
systemctl status unifi-analyzer      # is it running
journalctl -u unifi-analyzer -f      # what it is doing
```

The analyzer lives in `/opt/unifi-analyzer/app`, its data in
`/opt/unifi-analyzer/data`, and it runs as the unprivileged `analyzer` user.

## docassemble-lxc.sh

Creates an unprivileged Debian LXC and runs
[docassemble](https://github.com/jhpyle/docassemble) in it: a platform for
guided interviews and document assembly. You write an interview in YAML, it
asks someone the questions, and it hands back the filled-in documents.

docassemble is a Docker deployment. There is a bare-metal install path, but it
wants Python, PostgreSQL, Redis, RabbitMQ, Supervisor, uWSGI, nginx, texlive,
LibreOffice, pandoc and tesseract wired together by hand, and upstream tells
you plainly to use Docker instead. So the container has nesting turned on,
Docker CE installed, and the official all-in-one image running with
`CONTAINERROLE=all` — web, Celery, PostgreSQL, Redis and RabbitMQ in one place,
on one persistent volume. Docker inside an unprivileged container needs both
`nesting=1` and `keyctl=1`; the script sets both.

The image comes from upstream on every install and update. This repository
holds only the container script.

### Install

On the Proxmox VE host, as root:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/devsfan3/proxmox/main/docassemble-lxc.sh)"
```

It picks the next free container ID, the newest Debian template for the host's
architecture, and the first storage that will hold a root disk. When it
finishes it prints the address to open.

| | Default |
| --- | --- |
| Container | unprivileged Debian, `nesting=1,keyctl=1`, `onboot` |
| Resources | 4 cores, 8192 MB RAM, 2048 MB swap, 40 GB disk |
| Network | `vmbr1`, DHCP |
| Ports | 80 and 443, HTTP only |

**Budget twenty to forty minutes.** The image is about 6 GB, and docassemble
then spends another five to fifteen minutes on its first boot setting up
PostgreSQL, Redis, RabbitMQ and its Python environment. Nothing is wrong; it
is that slow once.

Override any of it from the environment, or pass `--advanced` to be asked:

```bash
CTID=210 CT_HOSTNAME=da MEMORY=16384 DISK=100 BRIDGE=vmbr0 \
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/devsfan3/proxmox/main/docassemble-lxc.sh)"
```

Settings: `CTID`, `CT_HOSTNAME`, `STORAGE`, `TEMPLATE_STORAGE`, `TEMPLATE`,
`CORES`, `MEMORY`, `SWAP`, `DISK`, `BRIDGE`, `VLAN`, `NET` (`dhcp` or a CIDR),
`GATEWAY`, `TIMEZONE`, `DA_HOSTNAME`, `DA_IMAGE`, `UNPRIVILEGED`.

Upstream asks for 4096 MB for the application alone and this container also
carries a database, a message queue and LibreOffice, so 8192 is the default and
the script warns below 4096. It refuses a `MEMORY` larger than the host has.

### Update

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/devsfan3/proxmox/main/docassemble-lxc.sh)" -- --update
```

Flags go after the `--`. It finds the container it built, pulls the current
image and recreates the application container on the same data volume, so
configuration, interviews, uploads and the database all survive. It says so and
stops if the image is already current. Add a container ID (`--update 210`) if
you have more than one.

Two other ways to the same thing: run the script *inside* the container and it
updates that container, or run `docassemble-update` in there directly.

How it was started is kept in `/etc/docassemble/run.env` rather than only in
the container's environment, so an update can recreate the container without
having to reconstruct the arguments.

### Worth knowing before you use it

**The default login is published.** A fresh instance is `admin@admin.com` with
the password `password`, which is in upstream's own documentation. It prompts
you to change it the first time you log in. Do that before the container is
reachable by anyone else.

**It serves plain HTTP.** Put a reverse proxy with TLS in front of it before it
sees anything real. What docassemble holds is interview answers — other
people's personal circumstances — and on port 80 that crosses your network in
the clear.

**docassemble writes its own address into the URLs it generates**, from
`DAHOSTNAME`. The script sets that to the container's address, which on DHCP
can change and take the links with it. Give the container a reservation or a
static address. Once it has a real name, set it in the Configuration page of
the web interface, or reinstall with `DA_HOSTNAME=da.example.com`.

**PostgreSQL runs inside the application container**, so stopping it is not
instant. Every stop path the script installs allows ten minutes: the Docker
container's `--stop-timeout`, the daemon's `shutdown-timeout`, systemd's
`TimeoutStopSec`, and the LXC's own `--startup down=600` so a host reboot does
not kill the database mid-write. Use `docassemble-restart` rather than
`docker restart`, which uses a ten second timeout. Do not shorten any of them.

**If Docker falls back to the `vfs` storage driver**, the install says so. It
copies whole layers instead of sharing them, so a 6 GB image costs several
times that and runs slower. It means overlayfs is unavailable on that
container's backing storage. Current Proxmox on ZFS is fine; this is a check,
not an expectation.

If the install fails before the image is pulled, the script destroys the
container rather than leaving a broken one behind. After that it keeps it — the
download is the expensive part, and the reason it is not serving is inside the
container you would be deleting.

### Afterwards

```bash
pct enter <CTID>          # a shell in the container
docassemble-logs          # what it is doing
docassemble-restart       # stop properly, then start
docassemble-update        # pull the current image, keep the data
docassemble-backup        # tar the data volume, application stopped
docassemble-shell         # a shell inside the docassemble container itself
```

Everything — configuration, the database, uploads, and every package installed
through the web interface — lives in the Docker volume `docassemble`, mounted
at `/usr/share/docassemble`. That volume is the whole instance. Back it up with
`docassemble-backup`, which stops the application first because a database
copied while it is being written to is not a backup, or take the whole
container with `vzdump`.

## cleanup-lxc-storage.sh

Reclaims disk space *inside* the containers you already run, with the leftovers
the community helper scripts create as they install and update: the old
`/opt/<app>_bak` tree an update moved aside, the release tarball it downloaded
next to it, the `.deb` still sitting in `/root`, package manager caches,
journald, rotated logs, and npm/pip/go build caches. Then it runs `pct fstrim`
so the freed blocks go back to a thin-LVM or ZFS pool instead of only back to
the guest filesystem.

### Run

On the Proxmox VE host, as root:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/devsfan3/proxmox/main/cleanup-lxc.sh)"
```

`cleanup-lxc.sh` fetches `cleanup-lxc-storage.sh` and runs it, so nothing has to
live on the host. **That command is a dry run**: it walks every container and
prints what it would delete, per category and per path, without deleting any of
it. When the list looks right, do it for real — flags go after the `--`:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/devsfan3/proxmox/main/cleanup-lxc.sh)" -- --apply
```

Or run the cleanup script directly, if you would rather keep a copy:

```bash
curl -fsSL -o cleanup-lxc-storage.sh https://raw.githubusercontent.com/devsfan3/proxmox/main/cleanup-lxc-storage.sh
bash cleanup-lxc-storage.sh --apply 105 110
```

### Options

| | |
| --- | --- |
| `--apply` | actually delete; without it, nothing is removed |
| `105 110` | only these container IDs (default: all of them) |
| `--exclude 100,101` | skip these |
| `--age N` | keep backups and downloads newer than N days (default 7) |
| `--journal-size 32M` | how much journald history to keep (default 64M) |
| `--aggressive` | also `/var/lib/apt/lists`, `/var/cache`, cargo, and truncate live `*.log` over 10 MB |
| `--docker` | `docker system prune -af` where docker is installed — images and build cache, never volumes |
| `--include-stopped` | start stopped containers to clean them, then shut them back down |
| `--no-trim` | skip `pct fstrim` |
| `-y` | do not ask before applying |

### What it will not touch

Anything newer than `--age` days, so the backup copy from an update you ran
this week is still there to roll back to. Templates. Stopped containers, unless
you ask for them. Docker volumes. Live log files, unless `--aggressive`, and
even then they are truncated rather than deleted so the process writing to them
keeps its file handle.

It works on Debian and Ubuntu containers (apt), Alpine (apk), and Fedora and
friends (dnf). Each run is logged to `/var/log/lxc-cleanup-<timestamp>.log` on
the host.

## upgrade-lxc-trixie.sh

Upgrades one container from Debian 12 to Debian 13 in place, with the two things
that go wrong on Proxmox handled before they can: systemd's credential plumbing,
and third-party apt repositories.

Debian 13 ships systemd 257, which turns on credentials by default and leaves an
unprivileged container failing every service with `status=243/CREDENTIALS`. The
script installs Debian's own `lxc.generator` first, so the container comes back
up rather than needing rescue from `pct enter`.

### Run

On the Proxmox VE host, as root:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/devsfan3/proxmox/main/upgrade-lxc-trixie.sh)" -- 105
```

Flags go after the `--`. It refuses to run on Proxmox VE 8, refuses a container
that is not bookworm, checks there is room for the upgrade, snapshots, then
rewrites sources, `full-upgrade`s without prompting, reboots and reports.

Third-party apt repositories are worked out rather than guessed at. For each
one, the script asks the publisher where it keeps trixie — `dists/<suite>/Release`
— and rewrites only what needs rewriting:

```
docker.list        bookworm       -> trixie
pgdg.list          bookworm-pgdg  -> trixie-pgdg
cloudflared.list   bookworm       -> any (no trixie, but distro-agnostic)
grafana.list       stable         not a Debian codename, left alone
```

That distinction matters more than it looks. A blind `sed` of bookworm to
trixie rewrites Grafana's `stable` suite into nothing, and leaves Docker's
`stable` *component* alone while missing that its suite needed changing. The
script only ever replaces the suite field, and only when the publisher has
something to serve there.

Anything with no trixie and no `any` is left on bookworm, reported, and you are
asked before the upgrade goes ahead. Those packages keep working; they stop
updating.

### Options

| | |
| --- | --- |
| `105` | the container to upgrade (required) |
| `--backup snapshot\|vzdump\|none` | how to make it undoable (default: snapshot) |
| `--storage NAME` | vzdump target storage (default: `local`) |
| `--third-party probe\|abort\|disable\|keep` | non-Debian repos: resolve each one against its publisher (default), stop and list them, rename them to `*.trixie-disabled`, or leave them exactly as they are |
| `--no-reboot` | upgrade, but leave the reboot to you |
| `-y` | do not ask before starting |

Probing runs from the Proxmox host, which always has curl. A container that
cannot reach a repository the host can will fail at `apt update` before
anything is upgraded, so the assumption is a cheap one.

### Afterwards

Roll back with `pct rollback <CTID> pretrixie_<timestamp>` — the script prints
the exact command when it finishes. Old repository files are kept inside the
container as `*.bookworm.bak`, and each run is logged to
`/var/log/lxc-trixie-<CTID>-<timestamp>.log` on the host.

PHP applications need their modules reinstalling afterwards; trixie moves to PHP
8.4 and nothing carries the old ones across. Check the application itself, not
only `systemctl --failed` — a service can start perfectly and still have lost
what it was pointed at.

To see what you are in for across a fleet before running anything, list the
foreign repositories first:

```bash
for id in $(pct list | awk 'NR>1 {print $1}'); do echo "=== $id ==="; pct exec $id -- grep -rhoE 'https?://[^ ]+' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null | grep -v debian.org | sort -u; done
```

## rebuild-lxc-trixie.sh

The other way to get to Debian 13: build a fresh container from the Debian 13
template, install the application into it, and move the data across. Worth the
extra effort for PHP applications, for anything you installed by hand outside
apt, and for containers that are already unwell — upgrading those carries the
problem forward.

It runs in phases, because the mechanical half can be automated and the other
half cannot. You write a short config per application saying where its data
lives; the script does everything else.

### Run

The workflow needs a config file on the host, so keep a copy rather than piping
it:

```bash
curl -fsSL -o rebuild-lxc-trixie.sh https://raw.githubusercontent.com/devsfan3/proxmox/main/rebuild-lxc-trixie.sh
curl -fsSL -o jellyfin.conf https://raw.githubusercontent.com/devsfan3/proxmox/main/examples/sample-app.conf
bash rebuild-lxc-trixie.sh full 105 206 --conf jellyfin.conf
```

`full` captures the data, creates container 206 shaped like 105, installs the
application, restores the data — and then **stops**. The new container is up on
DHCP with a fresh MAC, so it can be tested alongside the original, which has not
been touched. When it works:

```bash
bash rebuild-lxc-trixie.sh cutover 105 206
```

Cutover stops the old container, sets `onboot 0` on it, and moves its hostname,
static address and original MAC to the new one. `rollback 105 206` puts it all
back.

### Phases

| | |
| --- | --- |
| `capture <OLD>` | stops the services, dumps the databases, tars the declared paths, pulls it all to `/var/lib/vz/migrate/` with the old `pct config` |
| `create <OLD> <NEW>` | new container with the old one's cores, memory, features, storage and size; bind mounts reattached, volume mounts recreated empty |
| `provision <NEW>` | updates the base system, then runs your `PROVISION_CMD` |
| `restore <NEW>` | extracts the data *inside* the container so unprivileged id shifting is the kernel's problem, replays the database, fixes ownership |
| `cutover <OLD> <NEW>` | moves the identity across |
| `rollback <OLD> <NEW>` | undoes a cutover |

### The config

See `examples/sample-app.conf` for one backed by sqlite and
`examples/postgres-app.conf` for one with a real database. It is sourced by
bash:

| | |
| --- | --- |
| `SERVICES` | stopped before the data is read and before it is written back |
| `DATA_PATHS` | everything that must survive, as seen inside the container |
| `DB_TYPE` | `none`, `postgres` or `mysql` |
| `PROVISION_CMD` | how the application gets installed into the fresh container |
| `CHOWN_MAP` | `user:group /path` entries to reassert after extraction |
| `POST_RESTORE_CMD` | anything else once the data is in place |

Never put `/var/lib/postgresql` in `DATA_PATHS`. Set `DB_TYPE=postgres` and let
it dump and replay — a data directory written by PostgreSQL 15 will not start
under the 17 that trixie ships.

The capture is a full copy of the data on the host, so check `df` first if the
application is large. Data on bind mounts costs nothing: those are reattached to
the new container, not copied, so leave those paths out.

## Licence

These scripts are MIT. The UniFi Support File Analyzer and docassemble are
separate projects under their own licences. Nothing here is an official
Ubiquiti tool or has any connection to Ubiquiti, and nothing here is affiliated
with the docassemble project.
