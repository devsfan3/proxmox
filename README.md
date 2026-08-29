# proxmox

Scripts for building Proxmox VE containers, in the style of the community
helper scripts: run one line on the Proxmox host and get a working service.

Each script creates its own container, installs into it, and can update that
container later. Read a script before running it — everything below runs as
root on your hypervisor.

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

## Licence

These scripts are MIT. The UniFi Support File Analyzer is a separate project
under its own licence. Neither is an official Ubiquiti tool, and neither has
any connection to Ubiquiti.
