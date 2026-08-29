#!/usr/bin/env bash
#
# Create a Proxmox LXC and install the UniFi Support File Analyzer in it.
#
#   https://github.com/Inch-high/unifi-support-file-analyzer
#
# Run this on the Proxmox VE host, as root. Straight from the repository:
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/devsfan3/proxmox/main/unifi-analyzer-lxc.sh)"
#
# or from a copy of this file:
#
#   bash unifi-analyzer-lxc.sh              # defaults, no questions
#   bash unifi-analyzer-lxc.sh --advanced   # prompt for every setting
#   bash unifi-analyzer-lxc.sh --update     # update an install this made
#   bash unifi-analyzer-lxc.sh --update 210 # ... a particular container
#   bash unifi-analyzer-lxc.sh --update --force   # reinstall even if current
#
# Flags work with the one-liner too, after a --:
#
#   bash -c "$(curl -fsSL .../unifi-analyzer-lxc.sh)" -- --update
#
# --update finds the container this script built, pulls the latest analyzer,
# reinstalls its dependencies and restarts it. Run the same file inside the
# container and it updates that container, which is what the Proxmox helper
# scripts do. Inside the container there is also `unifi-analyzer-update`.
#
# It creates an unprivileged Debian container, installs the analyzer into a
# virtualenv under /opt/unifi-analyzer, and runs it from a systemd unit that
# starts on boot. The analyzer listens on every address in the container, so
# anyone on your LAN who knows the IP can open it: it has no login, and what
# it puts on screen is your network's addresses, device names and secrets.
# The service wipes its extracted data every time it starts, so a support file
# does not outlive the session that needed it.
#
# Everything below can also be set from the environment, which is what to use
# if you want no prompts and no defaults:
#
#   CTID=210 CT_HOSTNAME=ufa STORAGE=local-lvm CORES=8 bash unifi-analyzer-lxc.sh
#
set -euo pipefail

REPO_URL="https://github.com/Inch-high/unifi-support-file-analyzer.git"
APP_ROOT="/opt/unifi-analyzer"
SERVICE_USER="analyzer"

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
  RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; BLD=$'\033[1m'; RST=$'\033[0m'
else
  RED=''; GRN=''; YLW=''; BLD=''; RST=''
fi

info() { printf '%s==>%s %s\n' "$BLD" "$RST" "$*"; }
ok()   { printf '%s  ok%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '%swarn%s %s\n' "$YLW" "$RST" "$*"; }
die()  { printf '%s fail%s %s\n' "$RED" "$RST" "$*" >&2; exit 1; }

SCRIPT_REPO="devsfan3/proxmox"
SCRIPT_NAME="unifi-analyzer-lxc.sh"
SCRIPT_URL="https://raw.githubusercontent.com/$SCRIPT_REPO/main/$SCRIPT_NAME"

# How to invoke this script again, for the messages that suggest doing so. Run
# from a file, that is the file; run from a pipe, $0 is "bash" and the only
# honest answer is the one-liner.
if [ -f "$0" ] && [ "$(basename -- "$0")" != "bash" ]; then
  SELF="bash $0"
else
  SELF="bash -c \"\$(curl -fsSL $SCRIPT_URL)\" --"
fi

usage() {
  # The comment block at the top of this file is the help text; print it up to
  # the first line that is not a comment, so the two cannot drift apart.
  if [ -f "$0" ]; then
    awk 'NR>1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0"
  else
    echo "Piped from a URL, so there is no file to read the help out of."
    echo "See https://github.com/$SCRIPT_REPO"
  fi
  exit 0
}

ADVANCED=0
UPDATE=0
UPDATE_CTID=""
UPDATE_FORCE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --advanced|-a) ADVANCED=1 ;;
    --update|-u)   UPDATE=1
                   # An optional container id may follow. Anything starting
                   # with a dash is the next flag, not an id.
                   case "${2:-}" in
                     ''|-*) : ;;
                     *) UPDATE_CTID="$2"; shift ;;
                   esac ;;
    --force|-f)    UPDATE_FORCE="--force" ;;
    --help|-h)     usage ;;
    *)             die "Unknown option: $1  (try --help)" ;;
  esac
  shift
done

# ---------------------------------------------------------------------------
# Updating an existing install
# ---------------------------------------------------------------------------

# Run inside the container rather than on the host, which is how the Proxmox
# helper scripts behave: the same file both installs and updates, and which one
# it does depends on where you run it. Checked before the pct preflight, since
# there is no pct in here to find.
if [ ! -x /usr/local/bin/unifi-analyzer-update ] && [ "$UPDATE" = "1" ] \
   && ! command -v pct >/dev/null 2>&1; then
  die "No analyzer install here, and no pct — run this on the Proxmox host, or inside the container."
fi
if [ -x /usr/local/bin/unifi-analyzer-update ] && ! command -v pct >/dev/null 2>&1; then
  info "Updating the analyzer in this container"
  exec /usr/local/bin/unifi-analyzer-update $UPDATE_FORCE
fi

# Containers this script built. The description it sets carries the repository
# URL, which is the reliable marker; the hostname is checked too, because a
# container restored from a backup can lose the description but rarely the name.
find_analyzer_cts() {
  local id cfg
  for id in $(pct list 2>/dev/null | awk 'NR>1 {print $1}'); do
    cfg="$(pct config "$id" 2>/dev/null || true)"
    case "$cfg" in
      *unifi-support-file-analyzer*|*unifi-analyzer*) echo "$id" ;;
    esac
  done
}

do_host_update() {
  local target="$UPDATE_CTID" found count

  if [ -z "$target" ]; then
    found="$(find_analyzer_cts)"
    count="$(printf '%s' "$found" | grep -c . || true)"
    case "$count" in
      0) die "No analyzer container found. Pass the id: $SELF --update <CTID>" ;;
      1) target="$found"
         info "Found analyzer container $target" ;;
      *) echo "More than one analyzer container:" >&2
         # shellcheck disable=SC2086
         for id in $found; do
           printf '  %s  %s\n' "$id" "$(pct config "$id" | awk -F': ' '/^hostname:/ {print $2}')" >&2
         done
         die "Pick one: $SELF --update <CTID>" ;;
    esac
  fi

  pct status "$target" >/dev/null 2>&1 || die "No container $target on this host."

  if ! pct status "$target" | grep -q running; then
    info "Container $target is stopped — starting it"
    pct start "$target" >/dev/null
    for i in $(seq 1 30); do
      pct exec "$target" -- test -d /proc/1 >/dev/null 2>&1 && break
      [ "$i" = "30" ] && die "Container $target would not come up."
      sleep 1
    done
  fi

  # An install from before this command existed has no updater in it. Say so
  # plainly rather than failing with "command not found".
  pct exec "$target" -- test -x /usr/local/bin/unifi-analyzer-update 2>/dev/null \
    || die "Container $target has no unifi-analyzer-update — it was not installed by this script."

  pct exec "$target" -- /usr/local/bin/unifi-analyzer-update $UPDATE_FORCE \
    || die "Update failed inside container $target."
  ok "Container $target updated"
  exit 0
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
[ "$(id -u)" = "0" ] || die "Run this as root on the Proxmox host."
command -v pct >/dev/null 2>&1 || die "pct not found. This has to run on a Proxmox VE host, not inside a container."
command -v pveam >/dev/null 2>&1 || die "pveam not found. This has to run on a Proxmox VE host."

# First storage that will hold what we are about to put on it. Asking Proxmox
# is better than guessing "local-lvm", which plenty of installs do not have.
first_storage_for() {
  pvesm status -content "$1" 2>/dev/null | awk 'NR>1 && $3=="active" {print $1; exit}'
}

[ "$UPDATE" = "1" ] && do_host_update

# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------
CTID="${CTID:-$(pvesh get /cluster/nextid 2>/dev/null || echo 200)}"
CT_HOSTNAME="${HOSTNAME_OVERRIDE:-${CT_HOSTNAME:-unifi-analyzer}}"
CORES="${CORES:-4}"
MEMORY="${MEMORY:-4096}"
SWAP="${SWAP:-512}"
DISK="${DISK:-16}"
BRIDGE="${BRIDGE:-vmbr1}"
NET="${NET:-dhcp}"          # dhcp, or a CIDR such as 192.168.1.50/24
GATEWAY="${GATEWAY:-}"      # only used with a static CIDR
VLAN="${VLAN:-}"
PORT="${PORT:-8077}"
UNPRIVILEGED="${UNPRIVILEGED:-1}"
STORAGE="${STORAGE:-$(first_storage_for rootdir)}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-$(first_storage_for vztmpl)}"
TEMPLATE="${TEMPLATE:-}"    # a file name such as debian-13-standard_13.1-1_amd64.tar.zst

ask() {
  # ask <prompt> <varname>
  local prompt="$1" var="$2" current="${!2}" reply
  read -r -p "$prompt [$current]: " reply || true
  [ -n "$reply" ] && printf -v "$var" '%s' "$reply"
}

if [ "$ADVANCED" = "1" ]; then
  echo
  info "Container settings — press enter to keep the value shown."
  ask "Container ID"                CTID
  ask "Hostname"                    CT_HOSTNAME
  ask "Storage for the root disk"   STORAGE
  ask "CPU cores"                   CORES
  ask "Memory (MB)"                 MEMORY
  ask "Swap (MB)"                   SWAP
  ask "Disk size (GB)"              DISK
  ask "Network bridge"              BRIDGE
  ask "VLAN tag (blank for none)"   VLAN
  ask "Address — 'dhcp' or a CIDR"  NET
  if [ "$NET" != "dhcp" ]; then
    ask "Gateway"                   GATEWAY
  fi
  ask "Port the analyzer listens on" PORT
  ask "Unprivileged container (1/0)" UNPRIVILEGED
  echo
fi

[ -n "$STORAGE" ] || die "No active storage found that can hold a container root disk. Pass STORAGE=<name>."
if ! ip -o link show "$BRIDGE" >/dev/null 2>&1; then
  BRIDGES="$(ip -o link show type bridge 2>/dev/null | awk -F': ' '{print $2}' | tr '\n' ' ')"
  die "Bridge $BRIDGE does not exist on this host. Available: ${BRIDGES:-none}. Pass BRIDGE=<name>."
fi
[ -n "$TEMPLATE_STORAGE" ] || die "No active storage found that can hold container templates. Pass TEMPLATE_STORAGE=<name>."
pct status "$CTID" >/dev/null 2>&1 && die "Container $CTID already exists. Pick another CTID, or destroy it first: pct destroy $CTID"
[ "$NET" = "dhcp" ] || [ -n "$GATEWAY" ] || die "A static address needs a gateway. Pass GATEWAY=<ip>."

# ---------------------------------------------------------------------------
# Template
# ---------------------------------------------------------------------------
info "Finding a Debian template"
pveam update >/dev/null 2>&1 || warn "Could not refresh the template list; using what is cached."

if [ -z "$TEMPLATE" ]; then
  # Newest Debian standard template on offer, falling back a release at a time
  # so this keeps working after Proxmox retires or adds one.
  for series in debian-13-standard debian-12-standard debian-11-standard; do
    TEMPLATE="$(pveam available --section system 2>/dev/null \
                | awk -v s="$series" '$2 ~ s {print $2}' | sort -V | tail -1)"
    [ -n "$TEMPLATE" ] && break
  done
fi
[ -n "$TEMPLATE" ] || die "No Debian template available. Check the host's internet access, or pass TEMPLATE=<file>."

if pveam list "$TEMPLATE_STORAGE" 2>/dev/null | grep -qF "$TEMPLATE"; then
  ok "Template already downloaded: $TEMPLATE"
else
  info "Downloading $TEMPLATE to $TEMPLATE_STORAGE"
  pveam download "$TEMPLATE_STORAGE" "$TEMPLATE" >/dev/null || die "Template download failed."
  ok "Template downloaded"
fi
TEMPLATE_REF="$TEMPLATE_STORAGE:vztmpl/$TEMPLATE"

# ---------------------------------------------------------------------------
# Create the container
# ---------------------------------------------------------------------------
NET0="name=eth0,bridge=$BRIDGE"
[ -n "$VLAN" ] && NET0="$NET0,tag=$VLAN"
if [ "$NET" = "dhcp" ]; then
  NET0="$NET0,ip=dhcp"
else
  NET0="$NET0,ip=$NET,gw=$GATEWAY"
fi

info "Creating container $CTID ($CT_HOSTNAME) — ${CORES} cores, ${MEMORY}MB RAM, ${DISK}GB disk on $STORAGE"
pct create "$CTID" "$TEMPLATE_REF" \
  --hostname "$CT_HOSTNAME" \
  --ostype debian \
  --cores "$CORES" \
  --memory "$MEMORY" \
  --swap "$SWAP" \
  --rootfs "$STORAGE:$DISK" \
  --net0 "$NET0" \
  --unprivileged "$UNPRIVILEGED" \
  --features nesting=1 \
  --onboot 1 \
  --description "UniFi Support File Analyzer — $REPO_URL" \
  >/dev/null || die "pct create failed."
ok "Container created"

# Undo a half-built container rather than leaving one behind to clean up by
# hand. Only from here on: before this point there is nothing to remove.
cleanup_on_failure() {
  local code=$?
  [ "$code" = "0" ] && return 0
  warn "Install failed — removing container $CTID"
  pct stop "$CTID" >/dev/null 2>&1 || true
  pct destroy "$CTID" >/dev/null 2>&1 || true
  return "$code"
}
trap cleanup_on_failure EXIT

info "Starting container"
pct start "$CTID" >/dev/null || die "Container would not start."

# systemd being up is not the same as the network being usable, and apt fails
# in a way that reads like a broken mirror if you go too early.
info "Waiting for the network"
for i in $(seq 1 60); do
  if pct exec "$CTID" -- getent hosts deb.debian.org >/dev/null 2>&1; then
    ok "Network up"
    break
  fi
  [ "$i" = "60" ] && die "The container has no working DNS or network after 60s. Check the bridge, VLAN and gateway."
  sleep 1
done

# ---------------------------------------------------------------------------
# Provision inside the container
# ---------------------------------------------------------------------------
PROVISION="$(mktemp)"
cat > "$PROVISION" <<'PROVISION_EOF'
#!/usr/bin/env bash
set -euo pipefail

REPO_URL="__REPO_URL__"
APP_ROOT="__APP_ROOT__"
SERVICE_USER="__SERVICE_USER__"
PORT="__PORT__"

APP_DIR="$APP_ROOT/app"
DATA_DIR="$APP_ROOT/data"

export DEBIAN_FRONTEND=noninteractive

echo "--> Installing packages"
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  python3 python3-venv python3-pip git ca-certificates curl >/dev/null

echo "--> Creating the service account"
id -u "$SERVICE_USER" >/dev/null 2>&1 || \
  useradd --system --create-home --home-dir "$APP_ROOT" --shell /usr/sbin/nologin "$SERVICE_USER"
mkdir -p "$APP_ROOT" "$DATA_DIR"

echo "--> Cloning the analyzer"
if [ -d "$APP_DIR/.git" ]; then
  git -C "$APP_DIR" fetch --depth 1 origin
  git -C "$APP_DIR" remote set-head origin --auto >/dev/null
  git -C "$APP_DIR" reset --hard origin/HEAD
else
  git clone --depth 1 "$REPO_URL" "$APP_DIR"
fi

echo "--> Building the virtualenv"
python3 -m venv "$APP_DIR/.venv"
"$APP_DIR/.venv/bin/pip" install --quiet --upgrade pip
"$APP_DIR/.venv/bin/pip" install --quiet -r "$APP_DIR/requirements.txt"

# The venv is the one thing here the service account must not be able to write:
# it runs code out of it. Everything it does write lives in DATA_DIR.
chown -R root:root "$APP_DIR"
chown -R "$SERVICE_USER:$SERVICE_USER" "$DATA_DIR"
chmod 750 "$DATA_DIR"

echo "--> Installing the storage-clearing step"
mkdir -p "$APP_ROOT/bin"
cat > "$APP_ROOT/bin/clear-storage" <<'CLEAR_EOF'
#!/bin/sh
# Empty the analyzer's storage. Run before every start of the service: a
# support file holds real data about the network it came from, and there is no
# reason for it to outlive the session that needed it. Only the three
# directories the analyzer writes, and only their contents — the data
# directory itself is left in place because the service expects it to exist.
set -eu
DATA_DIR="${ANALYZER_DATA_DIR:-__APP_ROOT__/data}"
for sub in bundles uploads exports; do
    mkdir -p "$DATA_DIR/$sub"
    find "$DATA_DIR/$sub" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
done
CLEAR_EOF
chmod 755 "$APP_ROOT/bin/clear-storage"

echo "--> Writing the systemd unit"
cat > /etc/systemd/system/unifi-analyzer.service <<UNIT_EOF
[Unit]
Description=UniFi Support File Analyzer
Documentation=$REPO_URL
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_USER
WorkingDirectory=$APP_DIR
Environment=ANALYZER_DATA_DIR=$DATA_DIR
Environment=PYTHONUNBUFFERED=1
# Storage is emptied on every start, not on stop: a crash should not be able to
# leave a support file behind, and this way it cannot.
ExecStartPre=$APP_ROOT/bin/clear-storage
# 0.0.0.0 because a container reached from elsewhere has to answer on the
# address the rest of the LAN uses. There is no login in front of this.
ExecStart=$APP_DIR/.venv/bin/uvicorn analyzer.app:app --host 0.0.0.0 --port $PORT
Restart=on-failure
RestartSec=5
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=full
ProtectHome=yes
ReadWritePaths=$DATA_DIR

[Install]
WantedBy=multi-user.target
UNIT_EOF

echo "--> Installing the update command"
cat > /usr/local/bin/unifi-analyzer-update <<'UPDATE_EOF'
#!/usr/bin/env bash
# Update the UniFi Support File Analyzer in place: fetch the latest code,
# reinstall its dependencies, restart the service. Safe to run repeatedly.
#
#   unifi-analyzer-update           update if there is anything to update
#   unifi-analyzer-update --force   reinstall even when already current
#
set -euo pipefail
APP_DIR="__APP_ROOT__/app"
FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

[ "$(id -u)" = "0" ] || { echo "Run this as root." >&2; exit 1; }
cd "$APP_DIR"

OLD="$(git rev-parse HEAD)"
git fetch --quiet --depth 1 origin
git remote set-head origin --auto >/dev/null
NEW="$(git rev-parse origin/HEAD)"

if [ "$OLD" = "$NEW" ] && [ "$FORCE" = "0" ]; then
  echo "Already up to date (${OLD:0:7}). Use --force to reinstall anyway."
  exit 0
fi

echo "Updating ${OLD:0:7} -> ${NEW:0:7}"
git reset --quiet --hard "$NEW"

# Dependencies before the restart, so a failed install leaves the running
# service alone rather than restarting it onto a half-updated environment.
"$APP_DIR/.venv/bin/pip" install --quiet --upgrade pip
"$APP_DIR/.venv/bin/pip" install --quiet -r "$APP_DIR/requirements.txt"
chown -R root:root "$APP_DIR"

systemctl restart unifi-analyzer
sleep 2
if systemctl is-active --quiet unifi-analyzer; then
  echo "Now at ${NEW:0:7}; service restarted."
else
  echo "The service did not come back up. Recent log:" >&2
  journalctl -u unifi-analyzer --no-pager -n 40 >&2
  exit 1
fi
UPDATE_EOF
chmod 755 /usr/local/bin/unifi-analyzer-update

echo "--> Starting the service"
systemctl daemon-reload
systemctl enable --now unifi-analyzer >/dev/null

# Started is not the same as serving. Give uvicorn a moment, then ask it.
for i in $(seq 1 30); do
  if curl -fsS -o /dev/null "http://127.0.0.1:$PORT/"; then
    echo "--> Analyzer is answering on port $PORT"
    exit 0
  fi
  sleep 1
done

echo "The service did not answer on port $PORT. Recent log:" >&2
journalctl -u unifi-analyzer --no-pager -n 40 >&2
exit 1
PROVISION_EOF

# The placeholders keep the provisioning script above a single quoted heredoc,
# so nothing in it is expanded twice or mangled by the host's shell.
sed -i \
  -e "s|__REPO_URL__|$REPO_URL|g" \
  -e "s|__APP_ROOT__|$APP_ROOT|g" \
  -e "s|__SERVICE_USER__|$SERVICE_USER|g" \
  -e "s|__PORT__|$PORT|g" \
  "$PROVISION"

info "Installing the analyzer inside the container (a few minutes)"
pct push "$CTID" "$PROVISION" /root/provision.sh --perms 755
rm -f "$PROVISION"
pct exec "$CTID" -- bash /root/provision.sh || die "Provisioning failed inside the container."
pct exec "$CTID" -- rm -f /root/provision.sh

trap - EXIT

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
IP="$(pct exec "$CTID" -- hostname -I 2>/dev/null | awk '{print $1}')"
[ -n "$IP" ] || IP="<container ip>"

cat <<SUMMARY

${GRN}${BLD}UniFi Support File Analyzer is running.${RST}

  Open it at   ${BLD}http://$IP:$PORT${RST}
  Container    $CTID ($CT_HOSTNAME), ${CORES} cores, ${MEMORY}MB RAM, ${DISK}GB on $STORAGE
  Shell in     pct enter $CTID
  Service      systemctl status unifi-analyzer
  Logs         journalctl -u unifi-analyzer -f
  Update       $SELF --update
               (or from inside: pct exec $CTID -- unifi-analyzer-update)

${YLW}${BLD}Read this before you use it.${RST}
  There is no login. Anyone who can reach $IP:$PORT can open it, and what it
  shows is your network's addresses, your device names, and in the Privacy tab
  your secrets. Keep this container on a network you trust, or put it behind
  something that asks for a password.

  Extracted support files and cached analysis are wiped every time the service
  starts, which includes a reboot of the container. Drag a support file onto
  the page to analyze it. If you would rather keep the data between restarts,
  comment out the ExecStartPre line in
  /etc/systemd/system/unifi-analyzer.service and reload systemd.

  This is not an official Ubiquiti tool.

SUMMARY
