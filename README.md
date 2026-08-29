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

These scripts are MIT. The UniFi Support File Analyzer is a separate project
under its own licence. Neither is an official Ubiquiti tool, and neither has
any connection to Ubiquiti.
