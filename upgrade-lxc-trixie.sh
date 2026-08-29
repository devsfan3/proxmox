#!/usr/bin/env bash
#
# upgrade-lxc-trixie.sh - in-place Debian 12 (bookworm) -> 13 (trixie) upgrade
# for a single Proxmox LXC container.
#
# Run ON THE PROXMOX VE 9 HOST, as root:
#     ./upgrade-lxc-trixie.sh 105
#     ./upgrade-lxc-trixie.sh 105 --third-party disable --backup vzdump --storage local
#
# What it does, in order:
#   1. preflight  (PVE 9, container exists, is bookworm, enough disk)
#   2. resolve third-party apt repos per --third-party
#   3. take a snapshot or vzdump backup
#   4. install Debian's lxc.generator  (the 243/CREDENTIALS fix)
#   5. rewrite sources to trixie, full-upgrade, autoremove, modernize-sources
#   6. reboot the container and verify
#
# Everything is logged to /var/log/lxc-trixie-<CTID>-<timestamp>.log

set -euo pipefail

CTID=""
BACKUP="snapshot"        # snapshot | vzdump | none
THIRD_PARTY="probe"      # probe | abort | disable | keep
STORAGE="local"          # only used by --backup vzdump
DO_REBOOT=1
ASSUME_YES=0

GENERATOR_URL="https://sources.debian.org/data/main/d/distrobuilder/3.2-2/distrobuilder/lxc.generator"
SNAPNAME="pretrixie_$(date +%Y%m%d%H%M)"
LOG=""

# $0 is unreliable when piped from curl, so name ourselves explicitly.
SELF="$(basename "${BASH_SOURCE[0]:-}" 2>/dev/null || true)"
case "$SELF" in ""|-|--|bash|sh) SELF="upgrade-lxc-trixie.sh" ;; esac

usage() {
  cat <<USAGE
$SELF - in-place Debian 12 (bookworm) -> 13 (trixie) upgrade for one Proxmox LXC.

Run on the Proxmox VE 9 host, as root:
    $SELF <CTID> [options]
    $SELF 105 --third-party disable --backup vzdump --storage local

Order of operations:
  1. preflight  (PVE 9, container exists, is bookworm, enough disk)
  2. resolve third-party apt repos per --third-party
  3. take a snapshot or vzdump backup
  4. install Debian's lxc.generator  (the 243/CREDENTIALS fix)
  5. rewrite sources to trixie, full-upgrade, autoremove, modernize-sources
  6. reboot the container and verify
USAGE
  cat <<'USAGE'

Options:
  --backup snapshot|vzdump|none   default: snapshot
  --storage NAME                  vzdump target storage (default: local)
  --third-party probe|abort|disable|keep
        probe   (default) ask each non-Debian repo where it publishes trixie
                and rewrite it to that; leave version-independent repos alone
        abort   stop and list them so you can decide by hand
        disable rename them to *.trixie-disabled, re-enable them yourself later
        keep    leave them exactly as they are
  --no-reboot                     do the upgrade, skip the reboot + verify
  -y, --yes                       don't ask for confirmation
  -h, --help
USAGE
}

log()  { printf '%s  %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$LOG"; }
warn() { printf '%s  WARN: %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$LOG" >&2; }
die()  { printf '\nERROR: %s\n' "$*" | tee -a "$LOG" >&2; exit 1; }

confirm() {
  [[ $ASSUME_YES -eq 1 ]] && return 0
  read -r -p "$1 [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

in_ct() { pct exec "$CTID" -- "$@"; }

# ---------------------------------------------------------------- args
# A leading -- is how the curl one-liner separates its flags; harmless here.
if [[ "${1:-}" == "--" ]]; then shift; fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --backup)      BACKUP="${2:?}"; shift 2 ;;
    --storage)     STORAGE="${2:?}"; shift 2 ;;
    --third-party) THIRD_PARTY="${2:?}"; shift 2 ;;
    --no-reboot)   DO_REBOOT=0; shift ;;
    -y|--yes)      ASSUME_YES=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    -*)            echo "unknown option: $1" >&2; usage; exit 1 ;;
    *)             CTID="$1"; shift ;;
  esac
done

[[ -n "$CTID" ]] || { usage; exit 1; }
[[ "$CTID" =~ ^[0-9]+$ ]] || die "CTID must be numeric, got '$CTID'"
[[ "$BACKUP" =~ ^(snapshot|vzdump|none)$ ]] || die "--backup must be snapshot, vzdump or none"
[[ "$THIRD_PARTY" =~ ^(probe|abort|disable|keep)$ ]] || die "--third-party must be probe, abort, disable or keep"

LOG="/var/log/lxc-trixie-${CTID}-$(date +%Y%m%d%H%M%S).log"
touch "$LOG" 2>/dev/null || LOG="/tmp/lxc-trixie-${CTID}.log"

# ---------------------------------------------------------------- preflight
[[ $EUID -eq 0 ]] || die "run this as root on the Proxmox host"
command -v pct >/dev/null || die "pct not found - this must run on the PVE host, not inside the container"

pve_major="$(pveversion | sed -n 's|^pve-manager/\([0-9]*\)\..*|\1|p')"
[[ -n "$pve_major" ]] || die "could not parse pveversion output"
if (( pve_major < 9 )); then
  die "host is Proxmox VE $pve_major.x - Debian 13 containers need PVE 9. Upgrade the host first."
fi
log "host: Proxmox VE $pve_major.x, target container: $CTID"

pct config "$CTID" >/dev/null 2>&1 || die "no such container: $CTID"
hostname="$(pct config "$CTID" | sed -n 's/^hostname: //p')"
unpriv="$(pct config "$CTID" | sed -n 's/^unprivileged: //p')"
log "container $CTID (${hostname:-no hostname}), unprivileged=${unpriv:-0}"

was_stopped=0
if [[ "$(pct status "$CTID")" != "status: running" ]]; then
  was_stopped=1
  log "container is stopped, starting it"
  pct start "$CTID"
  for _ in $(seq 1 30); do
    [[ "$(pct status "$CTID")" == "status: running" ]] && break
    sleep 1
  done
fi
[[ "$(pct status "$CTID")" == "status: running" ]] || die "container failed to start"

codename="$(in_ct sh -c '. /etc/os-release 2>/dev/null; printf %s "${VERSION_CODENAME:-unknown}"')"
case "$codename" in
  bookworm) log "container is Debian 12 (bookworm) - good" ;;
  trixie)   die "container is already on trixie, nothing to do" ;;
  *)        die "container reports codename '$codename', this script only handles bookworm" ;;
esac

free_mb="$(in_ct sh -c "df -Pm / | awk 'NR==2 {print \$4}'")"
log "free space on /: ${free_mb} MB"
if (( free_mb < 2048 )); then
  warn "less than 2 GB free inside the container - a full-upgrade will probably run out of space"
  confirm "continue anyway?" || die "aborted"
fi

# ---------------------------------------------------------------- push helper
helper_local="$(mktemp)"
cat > "$helper_local" <<'INNER_EOF'
#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1

APT_OPTS=(-y -o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef)
TP_LIST=/root/.trixie-thirdparty.list

repo_files() {
  [ -f /etc/apt/sources.list ] && echo /etc/apt/sources.list
  for f in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
    [ -f "$f" ] && echo "$f"
  done
  return 0
}

case "${1:-}" in

  scan)
    : > "$TP_LIST"
    for f in $(repo_files); do
      foreign=0
      for u in $(grep -Eoi 'https?://[^ ]+' "$f" 2>/dev/null || true); do
        host=$(printf %s "$u" | awk -F/ '{print $3}')
        case "$host" in
          *.debian.org|debian.org) ;;
          *) foreign=1 ;;
        esac
      done
      [ "$foreign" = 1 ] && echo "$f" >> "$TP_LIST"
    done
    cat "$TP_LIST"
    ;;

  list-repos)
    # emit "file|uri|suite" for every third-party repo entry
    [ -s "$TP_LIST" ] || exit 0
    while read -r f; do
      [ -f "$f" ] || continue
      case "$f" in
        *.sources)
          awk -v F="$f" '
            /^[Uu][Rr][Ii][Ss]:/    { nu=0; for(i=2;i<=NF;i++) us[++nu]=$i }
            /^[Ss][Uu][Ii][Tt][Ee][Ss]:/  { ns=0; for(i=2;i<=NF;i++) ss[++ns]=$i
                             for(a=1;a<=nu;a++) for(b=1;b<=ns;b++)
                               print F "|" us[a] "|" ss[b] }
          ' "$f"
          ;;
        *)
          awk -v F="$f" '
            /^[[:space:]]*deb(-src)?[[:space:]]/ {
              for(i=1;i<=NF;i++) if($i ~ /^https?:/) { print F "|" $i "|" $(i+1); break }
            }
          ' "$f"
          ;;
      esac
    done < "$TP_LIST" | sort -u
    ;;

  apply-thirdparty)
    # act on the plan the host pushed in: REWRITE|file|uri|old|new
    [ -s /root/.trixie-tp-plan ] || exit 0
    while IFS='|' read -r verb f uri old new; do
      [ "$verb" = "REWRITE" ] || continue
      [ -f "$f" ] || continue
      [ -f "$f.bookworm.bak" ] || cp -a "$f" "$f.bookworm.bak"
      case "$f" in
        *.sources)
          awk -v o="$old" -v n="$new" '
            /^[Ss][Uu][Ii][Tt][Ee][Ss]:/ { out=$1; for(i=2;i<=NF;i++){ t=$i; if(t==o) t=n; out=out" "t }
                            print out; next }
            { print }' "$f" > /tmp/.tp.$$ ;;
        *)
          awk -v o="$old" -v n="$new" '
            /^[[:space:]]*deb(-src)?[[:space:]]/ {
              for(i=1;i<=NF;i++) if($i ~ /^https?:/) { if($(i+1)==o) $(i+1)=n; break }
              print; next }
            { print }' "$f" > /tmp/.tp.$$ ;;
      esac
      # write through the existing inode so owner and mode survive
      cat /tmp/.tp.$$ > "$f" && rm -f /tmp/.tp.$$
      echo "rewrote $f: $old -> $new"
    done < /root/.trixie-tp-plan
    ;;

  disable-thirdparty)
    [ -s "$TP_LIST" ] || exit 0
    while read -r f; do
      [ -f "$f" ] || continue
      mv -v "$f" "$f.trixie-disabled"
    done < "$TP_LIST"
    ;;

  pregen)
    # Debian's lxc.generator - stops systemd 257 from failing with 243/CREDENTIALS
    install -d /etc/systemd/system-generators
    install -m 0755 /root/.lxc.generator /etc/systemd/system-generators/lxc
    systemctl daemon-reload
    if [ -f /run/systemd/system/service.d/zzz-lxc-service.conf ]; then
      echo "lxc.generator active"
    else
      echo "WARNING: zzz-lxc-service.conf not created - generator may not have run"
    fi
    ;;

  preupgrade)
    apt-get update
    apt-get "${APT_OPTS[@]}" upgrade
    ;;

  sources)
    changed=0
    for f in $(repo_files); do
      if [ -s "$TP_LIST" ] && grep -Fxq "$f" "$TP_LIST"; then
        echo "skipping third-party: $f"
        continue
      fi
      if grep -q bookworm "$f"; then
        cp -a "$f" "$f.bookworm.bak"
        sed -i 's/bookworm/trixie/g' "$f"
        echo "rewrote: $f"
        changed=1
      fi
    done
    [ "$changed" = 1 ] || { echo "no repo file mentioned bookworm - refusing to continue"; exit 1; }
    apt-get update
    ;;

  upgrade)
    apt-get "${APT_OPTS[@]}" full-upgrade
    apt-get -y --purge autoremove
    apt-get autoclean
    apt modernize-sources -y >/dev/null 2>&1 || true
    apt-get update || true
    ;;

  verify)
    . /etc/os-release; echo "os: $PRETTY_NAME"
    echo "systemd: $(systemctl is-system-running 2>&1 || true)"
    echo "--- failed units ---"
    systemctl --failed --no-legend --no-pager || true
    ;;

  *)
    echo "unknown phase: ${1:-}" >&2; exit 1 ;;
esac
INNER_EOF

log "fetching lxc.generator on the host"
gen_local="$(mktemp)"
curl -fsSL "$GENERATOR_URL" -o "$gen_local" || die "could not download lxc.generator from $GENERATOR_URL"
[[ -s "$gen_local" ]] || die "downloaded lxc.generator is empty"

pct push "$CTID" "$helper_local" /root/.trixie-helper.sh --perms 0755
pct push "$CTID" "$gen_local"    /root/.lxc.generator   --perms 0644
rm -f "$helper_local" "$gen_local"

# ---------------------------------------------------------------- third-party repos
# Probing runs on the host: PVE always has curl, and a container that cannot
# reach a repo the host can will fail loudly at 'apt update' anyway.
probe_url() { curl -fsS -o /dev/null -m 10 -w '%{http_code}' "$1" 2>/dev/null || echo 000; }

mapfile -t tp < <(in_ct bash /root/.trixie-helper.sh scan)
if (( ${#tp[@]} == 0 )); then
  log "no third-party apt repos"
else
  log "third-party apt repos found:"
  printf '    %s\n' "${tp[@]}" | tee -a "$LOG"

  case "$THIRD_PARTY" in
    probe)
      log "working out where each of them publishes trixie"
      plan="$(mktemp)"; unresolved=0; rewrites=0; skipped=0
      while IFS='|' read -r f uri suite; do
        [[ -n "$uri" && -n "$suite" ]] || continue
        base="${uri%/}"
        if [[ "$suite" != *bookworm* ]]; then
          printf '    %-46s %-18s not a Debian codename, left alone\n' "$(basename "$f")" "$suite" | tee -a "$LOG"
          skipped=$(( skipped + 1 ))
          continue
        fi
        cand="${suite//bookworm/trixie}"
        if [[ "$(probe_url "$base/dists/$cand/Release")" == 200 ]]; then
          printf '    %-46s %-18s -> %s\n' "$(basename "$f")" "$suite" "$cand" | tee -a "$LOG"
          echo "REWRITE|$f|$uri|$suite|$cand" >> "$plan"
          rewrites=$(( rewrites + 1 ))
        elif [[ "$(probe_url "$base/dists/any/Release")" == 200 ]]; then
          printf '    %-46s %-18s -> any (no trixie, but distro-agnostic)\n' "$(basename "$f")" "$suite" | tee -a "$LOG"
          echo "REWRITE|$f|$uri|$suite|any" >> "$plan"
          rewrites=$(( rewrites + 1 ))
        else
          printf '    %-46s %-18s NO TRIXIE - staying on bookworm\n' "$(basename "$f")" "$suite" | tee -a "$LOG"
          echo "    ($base publishes neither $cand nor any)" | tee -a "$LOG"
          unresolved=$(( unresolved + 1 ))
        fi
      done < <(in_ct bash /root/.trixie-helper.sh list-repos)

      if (( rewrites > 0 )); then
        pct push "$CTID" "$plan" /root/.trixie-tp-plan
        in_ct bash /root/.trixie-helper.sh apply-thirdparty 2>&1 | tee -a "$LOG"
      fi
      rm -f "$plan"
      log "third-party repos: $rewrites rewritten, $skipped already version-independent, $unresolved unresolved"

      if (( unresolved > 0 )); then
        warn "$unresolved repo(s) have no trixie and no 'any' - they stay on bookworm."
        warn "Their packages keep working but stop updating. Check whether the vendor"
        warn "uses a suite name of its own (some publish 'stable'), or drop the repo."
        confirm "continue with those left on bookworm?" || die "aborted"
      fi
      ;;
    abort)
      die "re-run with --third-party probe (work out the right suite for each), disable (rename them aside) or keep (leave them exactly as they are), or fix them by hand first"
      ;;
    disable)
      log "disabling them"
      in_ct bash /root/.trixie-helper.sh disable-thirdparty | tee -a "$LOG"
      log "remember to re-add these repos with trixie suites after the upgrade"
      ;;
    keep)
      warn "leaving them exactly as they are - nothing here will be rewritten"
      ;;
  esac
fi

# ---------------------------------------------------------------- backup
case "$BACKUP" in
  snapshot)
    log "taking snapshot $SNAPNAME"
    if ! pct snapshot "$CTID" "$SNAPNAME" --description "before Debian 13 upgrade" 2>&1 | tee -a "$LOG"; then
      die "snapshot failed (storage may not support it) - use --backup vzdump --storage NAME, or --backup none if you already have one"
    fi
    ;;
  vzdump)
    log "running vzdump to storage '$STORAGE' (this can take a while)"
    vzdump "$CTID" --mode snapshot --compress zstd --storage "$STORAGE" 2>&1 | tee -a "$LOG" \
      || die "vzdump failed"
    ;;
  none)
    warn "no backup taken - you asked for this"
    confirm "really proceed with no backup?" || die "aborted"
    ;;
esac

# ---------------------------------------------------------------- go
echo
log "about to upgrade CT $CTID (${hostname:-unnamed}) from bookworm to trixie"
confirm "proceed?" || die "aborted"

log "[1/5] installing lxc.generator"
in_ct bash /root/.trixie-helper.sh pregen 2>&1 | tee -a "$LOG"

log "[2/5] bringing bookworm fully up to date"
in_ct bash /root/.trixie-helper.sh preupgrade 2>&1 | tee -a "$LOG"

log "[3/5] pointing apt at trixie"
in_ct bash /root/.trixie-helper.sh sources 2>&1 | tee -a "$LOG"

log "[4/5] full-upgrade - this is the long one, do not interrupt"
in_ct bash /root/.trixie-helper.sh upgrade 2>&1 | tee -a "$LOG"

if (( DO_REBOOT == 0 )); then
  log "skipping reboot as requested - reboot CT $CTID yourself, then check 'systemctl --failed'"
  exit 0
fi

log "[5/5] rebooting container"
pct reboot "$CTID" 2>&1 | tee -a "$LOG" || warn "pct reboot returned non-zero, checking state anyway"
for _ in $(seq 1 60); do
  [[ "$(pct status "$CTID")" == "status: running" ]] && in_ct true 2>/dev/null && break
  sleep 2
done
[[ "$(pct status "$CTID")" == "status: running" ]] || die "container is not running after reboot - roll back with: pct rollback $CTID $SNAPNAME"

sleep 5
echo
log "--- post-upgrade state ---"
in_ct bash /root/.trixie-helper.sh verify 2>&1 | tee -a "$LOG"

if (( was_stopped == 1 )); then
  log "container was stopped before the upgrade, stopping it again"
  pct stop "$CTID"
fi

cat <<EOS | tee -a "$LOG"

Done. Log: $LOG

Next:
  - check your application actually works, not just that systemd is happy
  - PHP apps: reinstall their modules (apt install php8.4-...)
  - if you used --third-party disable, re-add those repos with trixie suites
  - old repo files were kept as *.bookworm.bak inside the container
$( [[ "$BACKUP" == "snapshot" ]] && echo "  - roll back with:  pct rollback $CTID $SNAPNAME" )
$( [[ "$BACKUP" == "snapshot" ]] && echo "  - when happy:      pct delsnapshot $CTID $SNAPNAME" )
EOS
