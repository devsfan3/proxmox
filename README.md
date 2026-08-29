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

## Licence

These scripts are MIT. The UniFi Support File Analyzer is a separate project
under its own licence. Neither is an official Ubiquiti tool, and neither has
any connection to Ubiquiti.
