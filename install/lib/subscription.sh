#!/usr/bin/env bash
# subscription.sh — install the leaf subscription server and, optionally,
# the aggregator server (when --with-aggregator REMOTE_STATUS_URL is set).

# shellcheck source=./common.sh
[[ -n "${COMMON_SH_LOADED:-}" ]] || {
  echo "subscription.sh: source common.sh first" >&2
  exit 1
}

INSTALL_LIB_DIR=/usr/local/lib/anyreality-resi-stack
ENV_DIR=/etc/anyreality-resi-stack
PROFILE_DIR=/etc/anyreality-resi-stack/files
STATE_DIR=/var/lib/anyreality-resi-stack

prepare_aggregator_template_vars() {
  local protocol="${PROTOCOL:-anytls-reality}"
  local missing=()
  local required=(
    RESI_SERVER_IP
    RESI_UUID
    RESI_REALITY_PUBLIC_KEY
    RESI_NODE_NAME
  )
  # AnyReality authenticates with a per-server password, so the residential
  # node's password must be supplied for the dual profile to be usable.
  if [[ "$protocol" == "anytls-reality" ]]; then
    required+=(RESI_ANYTLS_PASSWORD)
  fi
  local name

  for name in "${required[@]}"; do
    [[ -n "${!name:-}" ]] || missing+=("$name")
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    die "--with-aggregator requires residential node variables in --config or environment: ${missing[*]}"
  fi

  RESI_SNI="${RESI_SNI:-addons.mozilla.org}"
  RESI_INBOUND_PORT="${RESI_INBOUND_PORT:-443}"
  RESI_SHORT_ID="${RESI_SHORT_ID:-}"
  RESI_ANYTLS_PASSWORD="${RESI_ANYTLS_PASSWORD:-}"

  DC_SERVER_IP="${DC_SERVER_IP:-${SERVER_IP:-}}"
  [[ -n "$DC_SERVER_IP" ]] || die "--with-aggregator requires SERVER_IP or DC_SERVER_IP"
  DC_UUID="${DC_UUID:-$UUID}"
  DC_REALITY_PUBLIC_KEY="${DC_REALITY_PUBLIC_KEY:-$REALITY_PUBLIC_KEY}"
  DC_SHORT_ID="${DC_SHORT_ID:-$SHORT_ID}"
  DC_SNI="${DC_SNI:-$SNI}"
  DC_INBOUND_PORT="${DC_INBOUND_PORT:-$INBOUND_PORT}"
  DC_NODE_NAME="${DC_NODE_NAME:-$NODE_NAME}"
  DC_ANYTLS_PASSWORD="${DC_ANYTLS_PASSWORD:-${ANYTLS_PASSWORD:-}}"

  export RESI_SERVER_IP RESI_UUID RESI_REALITY_PUBLIC_KEY RESI_NODE_NAME \
    RESI_SNI RESI_INBOUND_PORT RESI_SHORT_ID RESI_ANYTLS_PASSWORD \
    DC_SERVER_IP DC_UUID DC_REALITY_PUBLIC_KEY DC_SHORT_ID \
    DC_SNI DC_INBOUND_PORT DC_NODE_NAME DC_ANYTLS_PASSWORD
}

phase_subscription_leaf() {
  step "Installing subscription leaf server"

  : "${SUB_TOKEN:?}" "${INTERFACE:?}" "${NODE_NAME:?}"
  local total="${TOTAL_BYTES:-0}"
  local expire="${EXPIRE_TS:-0}"
  local protocol="${PROTOCOL:-anytls-reality}"

  # AnyReality is a sing-box-only protocol (Clash/mihomo cannot parse it), so
  # the default served profile is a full sing-box client config. VLESS+Vision
  # keeps the Clash YAML profile for the broad mihomo/Clash client ecosystem.
  local default_target
  if [[ "$protocol" == "vless-vision" ]]; then
    default_target="profile.yaml"
  else
    default_target="profile.json"
  fi

  run mkdir -p "$INSTALL_LIB_DIR" "$ENV_DIR" "$PROFILE_DIR" "$STATE_DIR"

  run cp "$REPO_ROOT/subscription/leaf_server.py" \
    "$INSTALL_LIB_DIR/leaf_server.py"

  write_file "$ENV_DIR/subscription-leaf.env" 0600 <<EOF
HOST=0.0.0.0
PORT=80
TOKEN=$SUB_TOKEN
INTERFACE=$INTERFACE
STATE_FILE=$STATE_DIR/usage-state.json
USAGE_OFFSET_BYTES=${USAGE_OFFSET_BYTES:-0}
BILLING_CYCLE_DAY=${BILLING_CYCLE_DAY:-1}
USAGE_POLL_INTERVAL_SECONDS=${USAGE_POLL_INTERVAL_SECONDS:-60}
COUNT_CURRENT_BOOT_ON_INIT=${COUNT_CURRENT_BOOT_ON_INIT:-true}
TOTAL_BYTES=$total
EXPIRE_TS=$expire
PROFILE_TITLE=$NODE_NAME
UPDATE_INTERVAL_HOURS=${UPDATE_INTERVAL_HOURS:-24}
REQUEST_TIMEOUT_SECONDS=${REQUEST_TIMEOUT_SECONDS:-10}
FILE_DIR=$PROFILE_DIR
DEFAULT_TARGET=$default_target
EOF

  # Serve one canonical profile as the default; drop any stale sibling so
  # switching protocols on re-run does not leave a mismatched file behind.
  run rm -f "$PROFILE_DIR/profile.yaml" "$PROFILE_DIR/profile.json"
  if [[ "$protocol" == "vless-vision" ]]; then
    render_template "$REPO_ROOT/templates/clash/client-single.yaml.tmpl" \
      "$PROFILE_DIR/profile.yaml" 0644
  else
    : "${ANYTLS_PASSWORD:?}"
    render_template "$REPO_ROOT/templates/singbox-client/client-single.json.tmpl" \
      "$PROFILE_DIR/profile.json" 0644
  fi

  run cp "$REPO_ROOT/templates/systemd/subscription-leaf.service" \
    /etc/systemd/system/subscription-leaf.service

  svc_enable_now subscription-leaf
  ok "Subscription leaf running on :80, token=$SUB_TOKEN ($protocol → $default_target)"
}

phase_subscription_aggregator() {
  step "Installing subscription aggregator server"

  : "${REMOTE_STATUS_URL:?}" "${SUB_TOKEN:?}" "${UUID:?}" "${REALITY_PUBLIC_KEY:?}"
  prepare_aggregator_template_vars

  local protocol="${PROTOCOL:-anytls-reality}"
  local default_target
  if [[ "$protocol" == "vless-vision" ]]; then
    default_target="profile.yaml"
  else
    default_target="profile.json"
  fi

  run mkdir -p "$INSTALL_LIB_DIR" "$ENV_DIR" "$PROFILE_DIR" "$STATE_DIR"

  run cp "$REPO_ROOT/subscription/aggregator_server.py" \
    "$INSTALL_LIB_DIR/aggregator_server.py"

  write_file "$ENV_DIR/subscription-aggregator.env" 0600 <<EOF
HOST=0.0.0.0
PORT=80
TOKEN=$SUB_TOKEN
REMOTE_STATUS_URL=$REMOTE_STATUS_URL
REMOTE_TIMEOUT_SECONDS=${REMOTE_TIMEOUT_SECONDS:-3}
MAX_REMOTE_STATUS_BYTES=${MAX_REMOTE_STATUS_BYTES:-65536}
FALLBACK_USED_BYTES=${FALLBACK_USED_BYTES:-0}
TOTAL_BYTES=${TOTAL_BYTES:-0}
EXPIRE_TS=${EXPIRE_TS:-0}
PROFILE_TITLE=${NODE_NAME:-Reality-Residential-Dual}
UPDATE_INTERVAL_HOURS=${UPDATE_INTERVAL_HOURS:-24}
REQUEST_TIMEOUT_SECONDS=${REQUEST_TIMEOUT_SECONDS:-10}
CACHE_FILE=$STATE_DIR/usage-cache.json
CACHE_TTL_SECONDS=${CACHE_TTL_SECONDS:-60}
REMOTE_POLL_INTERVAL_SECONDS=${REMOTE_POLL_INTERVAL_SECONDS:-${CACHE_TTL_SECONDS:-60}}
FILE_DIR=$PROFILE_DIR
DEFAULT_TARGET=$default_target
EOF

  # Render the dual-node profile with smart routing (TG → DC, OpenAI → Resi).
  # AnyReality ships a sing-box config; VLESS+Vision ships the Clash YAML.
  run rm -f "$PROFILE_DIR/profile.yaml" "$PROFILE_DIR/profile.json"
  if [[ "$protocol" == "vless-vision" ]]; then
    render_template "$REPO_ROOT/templates/clash/client-dual.yaml.tmpl" \
      "$PROFILE_DIR/profile.yaml" 0644
  else
    render_template "$REPO_ROOT/templates/singbox-client/client-dual.json.tmpl" \
      "$PROFILE_DIR/profile.json" 0644
  fi

  run cp "$REPO_ROOT/templates/systemd/subscription-aggregator.service" \
    /etc/systemd/system/subscription-aggregator.service

  svc_enable_now subscription-aggregator
  ok "Subscription aggregator running on :80, polling $REMOTE_STATUS_URL ($protocol → $default_target)"
}
