#!/usr/bin/env bash
# healthcheck.sh — read-only production health check for an installed
# anyreality-resi-stack node. Changes nothing; safe to run at any time.
#
# Installed by the installer as:
#   /usr/local/sbin/anyreality-resi-stack-healthcheck
#
# Usage:
#   anyreality-resi-stack-healthcheck           # human-readable report
#   anyreality-resi-stack-healthcheck --quiet   # print only problems (cron)
#
# Exit codes:
#   0  everything healthy (warnings may still be printed)
#   1  at least one FAIL — the node is degraded or down
#
# Cron alerting (mails you only when something is wrong, because cron mails on
# any output and --quiet stays silent while healthy):
#   */10 * * * * /usr/local/sbin/anyreality-resi-stack-healthcheck --quiet

set -Eeuo pipefail

CONF_DIR=/etc/sing-box/conf
LOG_DIR=/etc/sing-box/logs
ETC_DIR=/etc/anyreality-resi-stack
BACKUP_DIR=/var/backups/anyreality-resi-stack
HOOK_DIR=/etc/anyreality-resi-stack/backup-hooks.d
BACKUP_MAX_AGE_HOURS=48
DISK_WARN_PCT=80
DISK_FAIL_PCT=90
LOG_WARN_MB=50

QUIET=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -q | --quiet)
      QUIET=1
      shift
      ;;
    -h | --help)
      sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "Unknown arg: $1 (try --help)" >&2
      exit 2
      ;;
  esac
done

C_RESET=$'\033[0m'
C_GREEN=$'\033[1;32m'
C_YELLOW=$'\033[1;33m'
C_RED=$'\033[1;31m'

fails=0
warns=0

pass() {
  ((QUIET == 1)) || printf "%s[ OK ]%s %s\n" "$C_GREEN" "$C_RESET" "$*"
}
warn() {
  warns=$((warns + 1))
  printf "%s[WARN]%s %s\n" "$C_YELLOW" "$C_RESET" "$*" >&2
}
fail() {
  fails=$((fails + 1))
  printf "%s[FAIL]%s %s\n" "$C_RED" "$C_RESET" "$*" >&2
}

# ── sing-box ─────────────────────────────────────────────────────────────
if systemctl is-active --quiet sing-box; then
  pass "sing-box service is active"
else
  fail "sing-box service is NOT active — run: systemctl status sing-box"
fi

restarts="$(systemctl show sing-box -p NRestarts --value 2>/dev/null || echo 0)"
if [[ "$restarts" =~ ^[0-9]+$ ]] && ((restarts >= 5)); then
  warn "sing-box has restarted $restarts times — check journalctl -u sing-box for a crash loop"
else
  pass "sing-box restart count: ${restarts:-0}"
fi

if [[ -d "$CONF_DIR" ]] && command -v sing-box >/dev/null 2>&1; then
  if sing-box check -C "$CONF_DIR" >/dev/null 2>&1; then
    pass "sing-box config validates"
  else
    fail "sing-box config check FAILED — a restart would not come back up"
  fi
else
  fail "sing-box config directory $CONF_DIR missing or sing-box not installed"
fi

# Inbound port comes from the rendered config, not a hard-coded 443.
inbound_port="$(
  grep -ho '"listen_port"[[:space:]]*:[[:space:]]*[0-9]\+' "$CONF_DIR"/11_*.json 2>/dev/null |
    grep -o '[0-9]\+' | head -1
)"
inbound_port="${inbound_port:-443}"
if ss -tlnH 2>/dev/null | grep -qE "[:.]${inbound_port}[[:space:]]"; then
  pass "listening on tcp/${inbound_port}"
else
  fail "nothing is listening on tcp/${inbound_port} — clients cannot connect"
fi

# ── Subscription service (only if one is installed) ──────────────────────
sub_unit=""
for candidate in subscription-leaf subscription-aggregator; do
  if systemctl list-unit-files "${candidate}.service" >/dev/null 2>&1 &&
    [[ -f "/etc/systemd/system/${candidate}.service" ]]; then
    sub_unit="$candidate"
  fi
done

if [[ -n "$sub_unit" ]]; then
  if systemctl is-active --quiet "$sub_unit"; then
    pass "$sub_unit is active"
  else
    fail "$sub_unit is NOT active — subscription URLs are down"
  fi

  sub_port="$(awk -F= '/^PORT=/ {print $2}' "$ETC_DIR/${sub_unit}.env" 2>/dev/null | tail -1)"
  sub_port="${sub_port:-80}"
  # With TLS enabled the certificate is for a hostname, not 127.0.0.1, so -k is
  # correct here: this probes liveness, not certificate trust.
  sub_scheme="http"
  curl_opts=(-fsS --max-time 5)
  if grep -q '^TLS_CERT_FILE=.' "$ETC_DIR/${sub_unit}.env" 2>/dev/null; then
    sub_scheme="https"
    curl_opts+=(-k)
  fi
  if curl "${curl_opts[@]}" "${sub_scheme}://127.0.0.1:${sub_port}/healthz" >/dev/null 2>&1; then
    pass "subscription /healthz responds on ${sub_scheme}://:${sub_port}"
  else
    fail "subscription /healthz does not respond on ${sub_scheme}://:${sub_port}"
  fi

  # An expired certificate is a silent outage: clients refuse the subscription
  # while /healthz over -k keeps reporting green.
  if [[ "$sub_scheme" == "https" ]]; then
    cert_file="$(awk -F= '/^TLS_CERT_FILE=/ {print $2}' "$ETC_DIR/${sub_unit}.env" | tail -1)"
    if [[ -f "$cert_file" ]] && command -v openssl >/dev/null 2>&1; then
      if openssl x509 -in "$cert_file" -noout -checkend 604800 >/dev/null 2>&1; then
        pass "TLS certificate valid for at least 7 more days"
      else
        fail "TLS certificate expires within 7 days (or is unreadable): $cert_file"
      fi
    fi
  fi

  file_dir="$(awk -F= '/^FILE_DIR=/ {print $2}' "$ETC_DIR/${sub_unit}.env" 2>/dev/null | tail -1)"
  target="$(awk -F= '/^DEFAULT_TARGET=/ {print $2}' "$ETC_DIR/${sub_unit}.env" 2>/dev/null | tail -1)"
  file_dir="${file_dir:-$ETC_DIR/files}"
  if [[ -n "$target" && -s "$file_dir/$target" ]]; then
    pass "profile file present: $file_dir/$target"
  else
    fail "profile file missing or empty: ${file_dir}/${target:-<unset>} — subscriptions return 404"
  fi
fi

# ── Backups ──────────────────────────────────────────────────────────────
if systemctl is-enabled --quiet anyreality-resi-stack-backup.timer 2>/dev/null; then
  pass "backup timer is enabled"
  if [[ "$(systemctl is-failed anyreality-resi-stack-backup.service 2>/dev/null)" == "failed" ]]; then
    fail "last backup run FAILED — journalctl -u anyreality-resi-stack-backup.service"
  fi
  newest="$(find "$BACKUP_DIR" -name 'anyreality-resi-stack-*.tar.gz' -type f -print 2>/dev/null |
    sort | tail -1)"
  if [[ -z "$newest" ]]; then
    fail "no backup archive found in $BACKUP_DIR — there is nothing to roll back to"
  else
    age_h=$((($(date +%s) - $(stat -c %Y "$newest" 2>/dev/null || echo 0)) / 3600))
    if ((age_h > BACKUP_MAX_AGE_HOURS)); then
      warn "newest backup is ${age_h}h old (> ${BACKUP_MAX_AGE_HOURS}h): $newest"
    else
      pass "newest backup is ${age_h}h old: $(basename "$newest")"
    fi
  fi

  # Local-only backups do not survive losing the VPS.
  if find "$HOOK_DIR" -maxdepth 1 -type f -perm -u+x 2>/dev/null | grep -q .; then
    pass "off-box backup hook configured"
  else
    warn "no off-box backup hook in $HOOK_DIR — backups die with the host (see OPERATIONS.md)"
  fi
else
  warn "backup timer is not enabled — no rollback point is being produced"
fi

# ── Disk, logs, clock, firewall, secrets ─────────────────────────────────
disk_pct="$(df -P / | awk 'NR==2 {gsub("%","",$5); print $5}')"
if [[ "$disk_pct" =~ ^[0-9]+$ ]]; then
  if ((disk_pct >= DISK_FAIL_PCT)); then
    fail "root filesystem is ${disk_pct}% full — sing-box, journald and backups will start failing"
  elif ((disk_pct >= DISK_WARN_PCT)); then
    warn "root filesystem is ${disk_pct}% full"
  else
    pass "root filesystem ${disk_pct}% used"
  fi
fi

if [[ -f "$LOG_DIR/box.log" ]]; then
  log_mb=$(($(stat -c %s "$LOG_DIR/box.log" 2>/dev/null || echo 0) / 1024 / 1024))
  if ((log_mb > LOG_WARN_MB)); then
    warn "box.log is ${log_mb} MiB — check /etc/logrotate.d/sing-box and the error stream"
  else
    pass "box.log size ${log_mb} MiB"
  fi
fi

# Reality rejects handshakes whose clock is too far off, so a drifting clock
# looks exactly like "the protocol is blocked".
ntp_sync="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo "")"
if [[ "$ntp_sync" == "yes" ]]; then
  pass "clock is NTP-synchronised"
else
  warn "clock is NOT NTP-synchronised — Reality handshakes may fail (systemctl status chrony)"
fi

if command -v ufw >/dev/null 2>&1; then
  if ufw status 2>/dev/null | head -1 | grep -q "active"; then
    pass "UFW is active"
  else
    warn "UFW is not active"
  fi
fi

if [[ -f "$ETC_DIR/secrets.env" ]]; then
  mode="$(stat -c %a "$ETC_DIR/secrets.env" 2>/dev/null || echo "")"
  if [[ "$mode" == "600" ]]; then
    pass "secrets.env permissions are 600"
  else
    fail "secrets.env is mode ${mode:-unknown}, expected 600 — run: chmod 600 $ETC_DIR/secrets.env"
  fi
fi

# ── Summary ──────────────────────────────────────────────────────────────
if ((fails > 0)); then
  printf "%s%s check(s) FAILED, %s warning(s).%s\n" "$C_RED" "$fails" "$warns" "$C_RESET" >&2
  exit 1
fi
if ((warns > 0)); then
  ((QUIET == 1)) || printf "%sHealthy with %s warning(s).%s\n" "$C_YELLOW" "$warns" "$C_RESET"
  exit 0
fi
((QUIET == 1)) || printf "%sAll checks passed.%s\n" "$C_GREEN" "$C_RESET"
