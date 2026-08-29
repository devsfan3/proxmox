#!/usr/bin/env bash
#
# cleanup-lxc.sh - one-liner front end for cleanup-lxc-storage.sh.
#
# Fetches the current cleanup script from this repository and runs it, so the
# host never has to keep a copy. On the Proxmox VE host, as root:
#
#     bash -c "$(curl -fsSL https://raw.githubusercontent.com/devsfan3/proxmox/main/cleanup-lxc.sh)"
#
# That is a dry run: it reports what it would delete in every container and
# deletes nothing. Flags go after the --, and are passed through unchanged:
#
#     bash -c "$(curl -fsSL .../cleanup-lxc.sh)" -- --apply
#     bash -c "$(curl -fsSL .../cleanup-lxc.sh)" -- --apply --aggressive 105 110
#     bash -c "$(curl -fsSL .../cleanup-lxc.sh)" -- --help
#
# BRANCH=name runs the version on another branch.
#
set -euo pipefail

SCRIPT_REPO="devsfan3/proxmox"
SCRIPT_NAME="cleanup-lxc-storage.sh"
BRANCH="${BRANCH:-main}"
SCRIPT_URL="https://raw.githubusercontent.com/$SCRIPT_REPO/$BRANCH/$SCRIPT_NAME"

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

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "Run this as root on the Proxmox VE host."
command -v pct  >/dev/null 2>&1 || die "pct not found - this runs on the Proxmox VE host, not inside a container."
command -v curl >/dev/null 2>&1 || die "curl not found - apt-get install curl"

# ---------------------------------------------------------------------------
# Fetch
# ---------------------------------------------------------------------------
TMP="$(mktemp -t cleanup-lxc-storage.XXXXXX)"
trap 'rm -f "$TMP"' EXIT INT TERM

info "Fetching $SCRIPT_NAME ($BRANCH)"
curl -fsSL "$SCRIPT_URL" -o "$TMP" || die "Could not download $SCRIPT_URL"

# A proxy or a rate limit answers with a page, not a script. Check that what
# arrived is the thing we asked for before handing it to bash.
[ -s "$TMP" ] || die "Downloaded an empty file from $SCRIPT_URL"
head -1 "$TMP" | grep -q '^#!/usr/bin/env bash' \
  || die "That did not come back as a shell script - check $SCRIPT_URL in a browser"
grep -q 'reclaim disk space inside Proxmox LXC containers' "$TMP" \
  || die "Downloaded script is not $SCRIPT_NAME - refusing to run it"
bash -n "$TMP" || die "Downloaded script does not parse - refusing to run it"

ok "$(wc -c <"$TMP" | tr -d ' ') bytes, parses clean"

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
case " $* " in
  *" --apply "*) : ;;
  *" --help "*|*" -h "*) : ;;
  *) warn "Dry run - nothing is deleted. Add -- --apply when the list looks right." ;;
esac

chmod +x "$TMP"
bash "$TMP" "$@"
