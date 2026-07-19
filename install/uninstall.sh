#!/usr/bin/env bash
# uninstall.sh — stop services, remove units, optionally keep secrets/backups.
# Does NOT remove sing-box binary (apt-managed; uninstall manually if desired).

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export REPO_ROOT
COMMON_SH_LOADED=1
export COMMON_SH_LOADED
# shellcheck source=lib/common.sh
. "$REPO_ROOT/install/lib/common.sh"

require_root

KEEP_SECRETS=1
KEEP_BACKUPS=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --purge-secrets)
      KEEP_SECRETS=0
      shift
      ;;
    --purge-backups)
      KEEP_BACKUPS=0
      shift
      ;;
    --purge-all)
      KEEP_SECRETS=0
      KEEP_BACKUPS=0
      shift
      ;;
    *) die "Unknown arg: $1" ;;
  esac
done

step "Stopping and disabling services"
# The reality-resi-stack-backup.* entries clean up hosts that predate the
# rename to anyreality-resi-stack and never went through the migration phase.
for svc in sing-box subscription-leaf subscription-aggregator \
  anyreality-resi-stack-backup.timer reality-resi-stack-backup.timer; do
  systemctl is-enabled --quiet "$svc" 2>/dev/null && run systemctl disable --now "$svc" || true
done

step "Removing systemd units"
for unit in sing-box.service \
  subscription-leaf.service \
  subscription-aggregator.service \
  anyreality-resi-stack-backup.service \
  anyreality-resi-stack-backup.timer \
  reality-resi-stack-backup.service \
  reality-resi-stack-backup.timer; do
  [[ -f "/etc/systemd/system/$unit" ]] && run rm -f "/etc/systemd/system/$unit"
done
run systemctl daemon-reload

step "Removing config and runtime"
run rm -rf /etc/sing-box/conf /etc/sing-box/logs
run rm -rf /usr/local/lib/anyreality-resi-stack /usr/local/lib/reality-resi-stack
run rm -f /usr/local/sbin/backup-anyreality-resi-stack.sh /usr/local/sbin/backup-reality-resi-stack.sh
run rm -rf /var/lib/anyreality-resi-stack/usage-state.json /var/lib/anyreality-resi-stack/usage-cache.json \
  /var/lib/reality-resi-stack/usage-state.json /var/lib/reality-resi-stack/usage-cache.json

if [[ "$KEEP_SECRETS" == "0" ]]; then
  warn "Removing /etc/anyreality-resi-stack (secrets included)"
  run rm -rf /etc/anyreality-resi-stack /etc/reality-resi-stack
else
  info "Keeping /etc/anyreality-resi-stack (secrets retained; pass --purge-secrets to remove)"
fi

if [[ "$KEEP_BACKUPS" == "0" ]]; then
  warn "Removing /var/backups/anyreality-resi-stack"
  run rm -rf /var/backups/anyreality-resi-stack /var/backups/reality-resi-stack
else
  info "Keeping /var/backups/anyreality-resi-stack (pass --purge-backups to remove)"
fi

step "Removing UFW rules and fail2ban jail"
run ufw delete allow 443/tcp 2>/dev/null || true
run ufw delete allow 80/tcp 2>/dev/null || true
[[ -f /etc/fail2ban/jail.d/sshd.local ]] && run rm -f /etc/fail2ban/jail.d/sshd.local

ok "Uninstall complete. sing-box binary (apt-managed) left in place."
