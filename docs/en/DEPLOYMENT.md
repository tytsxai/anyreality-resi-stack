# Deployment

This document walks you from a blank Ubuntu/Debian VPS to a running node. Two paths:

- **Fast path**: a single `bash <(curl ...)` line that runs `install/install.sh`. This is the right answer 99% of the time.
- **Manual path**: source the `install/lib/*.sh` modules and call phase functions yourself, one at a time. Useful if you want to understand each step or if you're working inside a restricted network where you need to interleave operations.

Both paths produce identical end states.

### Protocol choice: AnyReality (default) vs VLESS-Vision (legacy)

The installer switches protocols with the `--protocol` flag (config variable `PROTOCOL`):

- **`--protocol anytls-reality` (default)**: AnyTLS + REALITY, or **AnyReality** for short. Under the hood it is sing-box's `anytls` inbound layered over `tls.reality`. AnyTLS's custom padding makes TLS-in-TLS harder to fingerprint, and Reality provides server-side camouflage (no certificate needed), so it is stronger on anti-detection than plain VLESS+Reality. Authentication uses a per-server random **password** (`ANYTLS_PASSWORD`) — there is no UUID/flow.
- **`--protocol vless-vision` (legacy)**: VLESS + Reality + xtls-rprx-vision, authenticated with a UUID + `flow`. Still fully supported, kept mainly for users who need Clash/mihomo.

⚠️ **AnyReality is only supported by the sing-box ecosystem; Clash / mihomo cannot parse AnyReality.** If your client uses the Clash core (Clash Verge, Stash, etc.), you must use `--protocol vless-vision`. Both protocols need no domain and no certificate; both generate a Reality private key and use the SNI for the handshake.

---

## 1. Prerequisites

### Server

- OS: Ubuntu 22.04 LTS or later, or Debian 12 or later
- Privileges: root or sudo
- Resources: 1 vCPU, 512 MiB RAM minimum (the installer adds 2 GiB swap), 10 GiB disk
- Network: public IPv4, ability to open `443/tcp`. If you enable the subscription server, also `80/tcp`.

### Local

- A machine that can SSH to the server.

### What you do **not** need

- ❌ A domain name
- ❌ A TLS certificate (Reality borrows the SNI handshake of a real public site)
- ❌ A Vercel / Cloudflare / third-party CDN account

---

## 2. Variables

Decide these before running. The installer prompts for missing values, but bundling everything into a `--config` file is cleanest:

| Variable | Example | Purpose |
|---|---|---|
| `NODE_NAME` | `US-Resi-01` | Display name shown in clients |
| `PROTOCOL` | `anytls-reality` | Protocol: `anytls-reality` (default, AnyReality) or `vless-vision` (legacy) |
| `SNI` | `addons.mozilla.org` | Reality handshake server — must be a real, reachable HTTPS site |
| `INBOUND_PORT` | `443` | sing-box listen port; keep `443` unless you have a reason |
| `SSH_PORT` | `22` | SSH port (so UFW keeps it open if you've changed it) |
| `INTERFACE` | `eth0` | Primary NIC; leave empty for auto-detection |
| `TIMEZONE` | `America/Los_Angeles` | Optional |
| `TOTAL_BYTES` | `1063004405760` | Plan quota in bytes (for the client usage card only); `0` hides it |
| `EXPIRE_TS` | `0` | Plan expiry Unix timestamp; `0` hides it |
| `BILLING_CYCLE_DAY` | `1` | Provider traffic reset day; set `11` for plans that reset on the 11th |
| `USAGE_POLL_INTERVAL_SECONDS` | `60` | Background usage sampling interval |
| `WITH_SUBSCRIPTION` | `1` | Install the subscription server (recommended) |
| `WITH_AGGREGATOR` | `0` | Install in aggregator mode (dual-node only) |
| `HARDEN_SSH` | `0` | Apply SSH key-only + port change (off by default, to avoid lockouts) |

---

## 3. Fast path: one-line install

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/tytsxai/anyreality-resi-stack/main/install/install.sh) \
  --node-name "US-Resi-01" \
  --sni addons.mozilla.org \
  --with-subscription
```

The script clones the repo to `/opt/anyreality-resi-stack/` and execs the full installer. Every phase prints progress. The default protocol is AnyReality; append `--protocol vless-vision` for the legacy VLESS-Vision protocol (for example when the client is Clash).
Before touching the machine, the installer validates ports, counters, billing
cycle day, hostnames, interface names, booleans, and the rendered profile host.
If public IP auto-detection fails, set `SERVER_IP` in `--config`; otherwise the
client profile would be rendered with an unusable empty server.

Remote-piped installs default to `main`. To pin a branch or tag, choose a published tag from [Releases](https://github.com/tytsxai/anyreality-resi-stack/releases), then run:

```bash
ANYREALITY_RESI_STACK_REF=<tag-or-branch> bash <(curl -fsSL https://raw.githubusercontent.com/tytsxai/anyreality-resi-stack/main/install/install.sh) \
  --node-name "US-Resi-01" \
  --with-subscription
```

**Strongly recommended**: do a `--dry-run` first:

```bash
bash <(curl -fsSL .../install.sh) --node-name "US-Resi-01" --dry-run
```

In `--dry-run` mode the installer **prints** every command it would run but changes nothing. Read the output, satisfy yourself you can live with each step, then re-run without `--dry-run`.

### With a `--config` file (better for automation)

```bash
cat > /root/install.env <<'EOF'
NODE_NAME=US-Resi-01
PROTOCOL=anytls-reality
SNI=addons.mozilla.org
INBOUND_PORT=443
INTERFACE=eth0
TIMEZONE=America/Los_Angeles
TOTAL_BYTES=1063004405760
EXPIRE_TS=0
BILLING_CYCLE_DAY=1
USAGE_POLL_INTERVAL_SECONDS=60
WITH_SUBSCRIPTION=1
EOF

bash <(curl -fsSL .../install.sh) --config /root/install.env --non-interactive
```

---

## 4. Manual path: phase-by-phase

If you want to see each step or run only a subset in a customized environment:

```bash
git clone --depth 1 https://github.com/tytsxai/anyreality-resi-stack.git /opt/anyreality-resi-stack
cd /opt/anyreality-resi-stack
export REPO_ROOT="$PWD" COMMON_SH_LOADED=1
. install/lib/common.sh
. install/lib/system.sh
. install/lib/singbox.sh

export NODE_NAME=US-Resi-01 SNI=addons.mozilla.org INBOUND_PORT=443 INTERFACE=eth0

phase_preflight        # OS / port / IPv4 / disk / RAM checks
phase_system_init      # apt deps + BBR + swap + journald limits
phase_install_singbox  # sing-box install with verified GPG fingerprint
phase_migrate_legacy_paths  # v1.x upgrade: move reality-resi-stack dirs/units to anyreality-resi-stack
phase_generate_keys    # Auth credential (AnyReality: ANYTLS_PASSWORD; VLESS-Vision: UUID) + Reality keypair + SUB_TOKEN
phase_configure_singbox  # Render /etc/sing-box/conf/*
phase_singbox_service  # systemd unit + enable --now
phase_firewall         # UFW + fail2ban
phase_verify           # End-to-end checks
```

Each phase is an independent function and is idempotent. Source is `install/lib/`.

**Upgrading from v1.x (reality-resi-stack)**: just re-run the installer. `phase_migrate_legacy_paths` moves the old `reality-resi-stack` directories under `/etc`, `/var/lib`, `/usr/local/lib`, and `/var/backups` to the `anyreality-resi-stack` prefix and retires the old `reality-resi-stack-backup` unit, so your existing UUID / Reality keys / password are reused and **already-imported clients keep working**.

---

## 5. Verification checklist

When the installer finishes it prints a "completion card". For AnyReality it lists the credentials you need for manual import (see below); for legacy VLESS-Vision it prints a `vless://` link. Verify by hand:

```bash
systemctl is-active sing-box                 # active
ss -tlnp | grep ':443'                       # sing-box listening
sing-box check -C /etc/sing-box/conf         # config validates
ufw status verbose                           # firewall rules
fail2ban-client status sshd                  # SSH jail
sysctl net.ipv4.tcp_congestion_control       # bbr
journalctl -u sing-box -n 20 --no-pager      # no errors on startup
```

Subscription server (if enabled):

```bash
curl -i http://127.0.0.1/healthz
curl -I http://YOUR_SERVER_IP/$(grep ^SUB_TOKEN /etc/anyreality-resi-stack/secrets.env | cut -d= -f2)
```

`curl -I` should show these response headers:

- `Content-Disposition`
- `Profile-Title`
- `Profile-Update-Interval`
- `Subscription-Userinfo`

The subscription URL is unchanged: `http://<server>/<TOKEN>/`. The default profile file depends on the protocol: AnyReality serves `profile.json` (a complete sing-box client config — a `mixed` inbound on `127.0.0.1:2080`, an `anytls-reality` outbound, and `route.final` pointing at the node), while legacy VLESS-Vision serves `profile.yaml` (Clash). The usage card / `Subscription-Userinfo` behavior is unchanged.

Client-side:

- Import the subscription URL. AnyReality needs a sing-box client (v2rayN, NekoBox, sing-box mobile, etc.); only legacy VLESS-Vision can be imported into Clash Verge. **Clash / mihomo cannot parse AnyReality.**
- Hit `https://api.openai.com/v1/models` — without an API key, expect a 401, which means the OpenAI path is up
- `curl --proxy socks5h://127.0.0.1:7891 https://ipinfo.io` should report your residential IP

**Credentials for manual AnyReality import** (read from the completion card or `/etc/anyreality-resi-stack/secrets.env`):

- `type=anytls`
- `server` = your server address, `port` = `INBOUND_PORT`
- `password` = `<ANYTLS_PASSWORD>`
- `tls.server_name` = `<SNI>`
- utls `fingerprint=chrome`
- reality `public_key` = `<REALITY_PUBLIC_KEY>`, `short_id` = `<SHORT_ID>`

Note that AnyReality has **no `flow` field**.

---

## 6. Upgrading sing-box

```bash
apt-get update && apt-get install --only-upgrade -y sing-box
systemctl restart sing-box
sing-box version
sing-box check -C /etc/sing-box/conf
```

If you're jumping multiple major versions, check the upstream [sing-box release notes](https://github.com/SagerNet/sing-box/releases) for schema breakage. The CHANGELOG.md in this repo records compatibility-tested versions.

For new installs that must stay on a known package build, pass the exact apt
package version:

```bash
bash /opt/anyreality-resi-stack/install/install.sh \
  --node-name "US-Resi-01" \
  --with-subscription \
  --singbox-version "<apt-package-version>"
```

If the version is not available in the Sagernet apt repository, `apt-get`
fails before any sing-box service is started.

---

## 7. Uninstall

```bash
bash /opt/anyreality-resi-stack/install/uninstall.sh
```

By default this preserves `/etc/anyreality-resi-stack/` (including secrets; do not share it publicly) and `/var/backups/anyreality-resi-stack/`. To wipe everything:

```bash
bash /opt/anyreality-resi-stack/install/uninstall.sh --purge-all
```

⚠️ `--purge-all` deletes the auth credential (AnyReality's `ANYTLS_PASSWORD` or the legacy VLESS UUID) and the Reality keys; they cannot be recovered, and every client subscription becomes invalid.

---

## 8. Next

- First deployment, step by step → [BEGINNER_GUIDE.md](BEGINNER_GUIDE.md)
- Importing into clients → [CLIENTS.md](CLIENTS.md)
- Subscription server design → [SUBSCRIPTION.md](SUBSCRIPTION.md)
- Enabling dual-node + smart routing (fixes Telegram soft-throttle, etc.) → [DUAL-NODE.md](DUAL-NODE.md)
- Choosing between this stack, 3x-ui, x-ui, and manual config → [COMPARISON.md](COMPARISON.md)
- Things go wrong → [TROUBLESHOOTING.md](TROUBLESHOOTING.md)
