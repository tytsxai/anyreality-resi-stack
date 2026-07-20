# Changelog

All notable changes to this project will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- **Client profiles now ship with complete routing rules.** The generated sing-box profiles previously only had an `ip_is_private → direct` rule and sent *everything* else through the node — which is unusable in TUN mode, where there is no global/direct toggle and domestic traffic silently detours abroad. Both `client-single.json.tmpl` and `client-dual.json.tmpl` now render a four-layer stack: baseline (`sniff`, `hijack-dns`, private-direct), ad/tracker `reject`, China-direct, and a fallback that rejects UDP/443 before sending the rest to the node. The Clash templates gain the matching ad-block rule and inline safety net.
- China-direct is deliberately two-tier: an inline ~60-entry `domain_suffix` safety net is evaluated *before* the remote `geosite-cn` / `geoip-cn` rule sets. The rule sets are downloaded from GitHub, which is commonly unreachable at first start — when that download fails the set is empty and every domestic site gets proxied. The inline list needs no network request, so high-traffic domestic services stay direct regardless. `download_detour` routes rule-set downloads through the node.
- Client profiles now include a DNS section that splits resolution (domestic names via `223.5.5.5`, everything else over DoT through the node) plus `experimental.cache_file` for rule-set persistence.
- [`docs/zh-CN/ROUTING.md`](docs/zh-CN/ROUTING.md) / [`docs/en/ROUTING.md`](docs/en/ROUTING.md): the routing model, how to add or remove domains, how to change the defaults, and how to verify a domain really goes direct without being fooled by a TUN client hijacking the test.
- `SECURITY.md` documents the subscription URL exposure surface: the profile is served over plain HTTP on :80 and contains the node password, so the URL is a credential; anything placed in `FILE_DIR` is served under the same token path, so backups must not go there.
- `tests/test_content_disposition.py` locks the `Content-Disposition` header shape.

### Fixed

- `Content-Disposition` now emits a plain ASCII `filename="…"` alongside the RFC 5987 `filename*=UTF-8''…` form, and percent-encodes the latter. Clients that cannot parse the header invent a numeric snowflake id for the imported profile; the previous value omitted the fallback and left non-ASCII names unencoded.
- `uninstall.sh` no longer aborts partway through. Two `[[ -f … ]] && rm …` loop bodies returned non-zero when the last candidate file was absent — the normal case — which `set -Eeuo pipefail` turned into an aborted uninstall that left UFW rules and the fail2ban jail behind.
- `uninstall.sh` now removes the UFW rule for the port actually configured in `/etc/sing-box/conf` instead of assuming 443, and deliberately leaves SSH rules alone.
- `--dry-run` works on a host that already has `secrets.env`. The reuse path returned without defining the template variables, so the next phase died with an unbound-variable error; dry-run now exports obvious placeholders instead of reading real secrets.
- `phase_firewall` no longer risks locking you out. `--ssh-port N` only tells UFW which port to keep open — it does not move sshd (that is `--harden-ssh`) — so passing a port sshd was not listening on fenced off the real one at `ufw --force enable`. The ports sshd is actually bound to are now always allowed, with a warning.
- A failing `--harden-ssh` phase is no longer swallowed by a trailing `|| true`.

## [2.0.0] — 2026-07-19

> **Project renamed to `anyreality-resi-stack`** (formerly `reality-resi-stack`). GitHub automatically redirects old repository URLs, so existing `curl | bash` install commands keep working. Runtime filesystem paths (`/etc`, `/var/lib`, `/usr/local/lib`, `/var/backups`), systemd unit names, the backup script/archives, and the environment variable (now `ANYREALITY_RESI_STACK_REF`, with the legacy `REALITY_RESI_STACK_REF` still honored) are all renamed to the `anyreality-resi-stack` prefix. Upgrading a v1.x host runs a migration phase (`phase_migrate_legacy_paths`) that moves the old `reality-resi-stack` directories to the new prefix and retires the old backup unit, so existing secrets, usage state, backups, and therefore already-imported clients are preserved.
>
> **Breaking — default protocol changed.** Fresh installs now default to **AnyReality (AnyTLS + Reality)** instead of VLESS + Reality + xtls-rprx-vision. Existing servers keep their current protocol until the installer is re-run. AnyReality is sing-box-only; if you rely on Clash/mihomo clients, install (or re-run) with `--protocol vless-vision` to stay on the legacy protocol. Because AnyReality authenticates with a password rather than a UUID/flow and the default subscription file changed from `profile.yaml` to `profile.json`, clients must be re-imported after switching protocols.

### Changed

- **AnyTLS + REALITY (AnyReality) is now the default protocol.** New installs deploy a sing-box `anytls` inbound fronted by Reality, authenticated with a per-server password (`ANYTLS_PASSWORD` in `secrets.env`). AnyTLS's custom padding hardens against TLS-in-TLS fingerprinting while Reality keeps the certless server camouflage. Still no domain or TLS certificate required.
- The default subscription profile is now a full sing-box client config served as `profile.json` (mixed inbound on `127.0.0.1:2080`, AnyReality outbound, domain-based routing in dual-node mode); the legacy Clash `profile.yaml` is served only under `--protocol vless-vision`.
- Runtime layout renamed to the `anyreality-resi-stack` prefix: `/etc/anyreality-resi-stack`, `/var/lib/anyreality-resi-stack`, `/usr/local/lib/anyreality-resi-stack`, `/var/backups/anyreality-resi-stack`, `/opt/anyreality-resi-stack`, the `backup-anyreality-resi-stack.sh` script and `anyreality-resi-stack-*.tar.gz` archives, and the `anyreality-resi-stack-backup` systemd units. A new `phase_migrate_legacy_paths` installer phase migrates existing `reality-resi-stack` hosts in place; `uninstall.sh` also cleans up either prefix.

### Added

- `--protocol anytls-reality` (default) / `--protocol vless-vision` (legacy) selects the inbound protocol. VLESS + Reality + xtls-rprx-vision remains fully supported for Clash/mihomo users, which cannot parse AnyReality.
- AnyReality templates: `templates/singbox/11_anytls-reality_inbounds.json.tmpl` (server inbound), `templates/singbox-client/anytls-outbound.json.tmpl`, and full sing-box client configs `templates/singbox-client/client-single.json.tmpl` / `client-dual.json.tmpl` (dual-node smart routing via sing-box `route` rules).
- Installers predating AnyReality mint and append an `ANYTLS_PASSWORD` to an existing `secrets.env` on re-run, so switching to `--protocol anytls-reality` works without regenerating the UUID or Reality keypair. Re-running with a different protocol drops the stale inbound and profile file to avoid port collisions or format mismatches.

### Fixed

- Leaf subscription accounting now samples interface counters while holding the state lock, preventing concurrent requests/background polling from applying stale samples out of order.
- Aggregator usage cache writes now use per-thread temporary files plus atomic replace, avoiding `.tmp` collisions during concurrent refreshes.
- Backup archives now exclude hidden runtime `.tmp` state/cache files and place `manifest.txt` at the archive root.
- Leaf subscription accounting now keeps usage fresher by sampling in the background every `USAGE_POLL_INTERVAL_SECONDS` seconds instead of only updating when a client pulls the subscription URL.
- Leaf subscription accounting now supports provider billing reset days via `BILLING_CYCLE_DAY`, so plans that reset on the 11th do not roll over on the 1st by mistake.
- Leaf subscription accounting now counts bytes already present in the current boot on first state creation by default (`COUNT_CURRENT_BOOT_ON_INIT=true`), while still supporting baseline-only mode and `USAGE_OFFSET_BYTES` calibration.
- Leaf accounting now carries usage forward across reboots or NIC counter rollovers by adding the new boot's current counter instead of silently dropping it.
- Aggregator subscription accounting now refreshes the leaf status cache in the background via `REMOTE_POLL_INTERVAL_SECONDS`, keeping usage cards warm even before the next client request.
- Re-running the installer with an existing `secrets.env` re-exports the reused UUID, Reality keys, subscription token, and short ID before rendering templates.
- `--with-subscription` and `--with-aggregator` are now mutually exclusive, and aggregator installs fail early unless the residential-node template variables are provided.

### Added

- `ANYREALITY_RESI_STACK_REF` lets remote-piped installs fetch a specific branch or tag while defaulting to `main`.
- Standard-library `unittest` coverage for leaf accounting and aggregator cache fallback, wired into `make test` and GitHub Actions.
- `make mdcheck` now falls back to `npx --yes markdown-link-check` when the binary is not installed globally, retries transient link-checker failures once, and GitHub Actions runs the same Markdown link gate.

### Security

- Aggregator leaf-status polling now caps each remote status response with `MAX_REMOTE_STATUS_BYTES` (default 64 KiB) before parsing JSON.
- Subscription systemd units now use basic sandboxing (`NoNewPrivileges`, `PrivateTmp`, `ProtectHome`, `ProtectSystem=strict`) and only keep `/var/lib/anyreality-resi-stack` writable.
- Config backups now exclude runtime usage/cache state, set backup directory permissions to `700`, and write archives as `600`.

## [1.0.3] — 2026-05-19

### Added (Documentation)

- **`llms.txt`** — AI-search-engine index covering what the toolkit does, what it does NOT do, common questions ("Why is Telegram slow on residential IP?", "Why does OpenAI block my data-center VPS?"), and long-tail search phrases (residential IP VLESS, ChatGPT 住宅 IP 出口, Telegram 住宅 IP 卡顿, etc.).
- **README — FAQ section** with 7 Q&As covering the residential-vs-data-center dichotomy, idempotent re-runs, Reality-no-domain, 3x-ui/XHTTP-Installer comparison, and GPL-3.0 implications.
- **README — Keywords block + nav row** (Release / Docs / llms.txt / Changelog / Issues).

### Notes

Documentation-only release. Installer behavior is unchanged from v1.0.2; users running v1.0.2 do not need to re-deploy.

## [1.0.2] — 2026-05-17

### Added

- `phase_preflight` now refuses to proceed if it detects a pre-existing manual sing-box install (`/usr/local/bin/sing-box` present without the apt-managed `/usr/bin/sing-box`) **or** a foreign systemd unit matching `sing-box*.service` other than the default `sing-box.service`. Without this check, `apt install sing-box` silently adds a second binary and a second systemd unit alongside the existing manual install — both apparently inactive at install time, but the next reboot or any `systemctl start sing-box` would race against the user's working unit on ports 443/8443 and config paths. Caught the hard way by attempting v1.0.1 verification against a real production host that turned out to already host a manually-installed sing-box.

## [1.0.1] — 2026-05-17

### Fixed

- **Critical**: pinned `SINGBOX_APT_KEY_FPR` in `install/lib/singbox.sh` was a placeholder that did not match the real Sagernet GPG key bundle, causing **every real install to fail at `phase_install_singbox`** with a fingerprint-mismatch abort. Bug was not caught by `--dry-run` because dry-run intentionally skips the GPG check. Now pinned to the primary fingerprint `2C317FBD5D886B4E89BAE8DA6D9152172A2B2F0C` and verified against the live key file on Ubuntu 24.04 LTS.
- **Critical**: `phase_verify` ran live `systemctl` / `ss` / `sing-box check` calls in `--dry-run` mode, producing fake-looking failures and a non-zero installer exit even though nothing had been installed. Now correctly no-ops in dry-run.
- GPG verification logic now requires the pinned fingerprint to be **present anywhere in the bundle** rather than to be the first fingerprint — Sagernet bundles a primary key plus a signing subkey, so the first-fingerprint check was fragile against subkey rotation.

### Note for users of 1.0.0

v1.0.0 was withdrawn within an hour of publication due to the GPG fingerprint bug above — please use v1.0.1 or later. Sorry for the noise.

## [1.0.0] — 2026-05-17 (withdrawn)

Initial release. **Withdrawn** — see 1.0.1 changelog for the install-blocking bug found 30 minutes after publication.

### Added

- **Modular bash installer** (`install/install.sh` + 5 lib modules) for Ubuntu 22.04+ / Debian 12+. Phases: preflight → system tuning → sing-box install with verified GPG fingerprint → key generation → config render → systemd service → firewall (UFW + fail2ban) → optional SSH hardening → optional subscription server → backup timer → end-to-end verification. Idempotent, supports `--dry-run`, `--non-interactive`, `--config`.
- **VLESS + Reality + xtls-rprx-vision** server config templates (`templates/singbox/`) with no domain or TLS cert required.
- **Two Python subscription servers** (`subscription/leaf_server.py`, `subscription/aggregator_server.py`) — zero third-party dependencies, standard library only.
  - Leaf reads `/sys/class/net/<iface>/statistics/*_bytes` for monthly traffic accounting, emits `Subscription-Userinfo` / `Profile-Title` / `Profile-Update-Interval` headers.
  - Aggregator polls a leaf's `/status` endpoint, caches the result, and falls back to cached values during leaf outages (prevents "0 bytes used" jitter in client usage cards).
- **Smart routing Clash template** (`templates/clash/client-dual.yaml.tmpl`) for dual-node deployments:
  - Routes OpenAI / Anthropic / Claude / Google AI / Netflix / banking domains through the residential node (where residential-IP reputation is an asset).
  - Routes Telegram / Discord / messenger domains through the data-center node (avoiding the "residential IP soft-throttle" problem common to messenger services).
- **Hash-only secret denylist** (`scripts/.redact-denylist.sha256`) plus shape-based detector (`scripts/redact.sh`) — CI fails on any UUID, Reality key, or known-leaked IP.
- **Deterministic example generator** (`scripts/make-example.sh`) using RFC 5737 documentation IPs and sentinel UUIDs.
- **Daily systemd-timer backup** of configuration (excludes runtime state, secrets are mode-600).
- **Bilingual documentation**: 5 docs in `docs/zh-CN/` (DEPLOYMENT, SUBSCRIPTION, DUAL-NODE, TROUBLESHOOTING, CLIENTS) with English mirrors in `docs/en/`.
- **GitHub Actions CI**: shellcheck, shfmt, ruff, yamllint, jsonlint, plus the redact gate.

### Security

- sing-box apt repo signing key fingerprint pinned (`SINGBOX_APT_KEY_FPR`). Installer refuses to proceed on fingerprint mismatch — defense against supply-chain compromise.
- `secrets.env` written mode 600, owned by root.
- `.gitignore` aggressively blocks credential file patterns at the git layer; CI redact gate is the second line.

## Roadmap

### v1.1+ (community-demand-driven)

- Additional translations (Farsi, Russian, Arabic, Vietnamese, Turkish, Indonesian, Burmese, Spanish — based on issue requests)
- GitHub Pages site with proper sitemap + hreflang
- Asciinema cast of the installer flow

### v2 (not committed)

- Optional automated SNI rotation
- Optional Cloudflare WARP-style ECH support if sing-box stable adds it
- Three-node mesh aggregator
