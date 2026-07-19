# Client import

> **The default protocol is now AnyReality (AnyTLS + REALITY).** The installer defaults to `--protocol anytls-reality`; the old VLESS + Reality + xtls-rprx-vision is now a legacy option, `--protocol vless-vision`. The trade-off: AnyReality resists detection better (AnyTLS custom padding makes TLS-in-TLS harder to target, and Reality adds server-side camouflage), but only sing-box-family clients support it; vless-vision is slightly weaker on detection resistance but works with Clash-family clients. Neither needs a domain or certificate.

After install, the server prints a subscription URL (if you used `--with-subscription`), or — only under legacy `vless-vision` — a `vless://` link.

**The subscription URL itself does not change; what changes is what it returns:**

- Default AnyReality → returns a full sing-box config `profile.json`; import it with a sing-box-family client that supports AnyReality.
- Legacy vless-vision → returns Clash YAML `profile.yaml`; import it with a Clash-family client. The `vless://` share link also only applies to vless-vision.

**Strongly prefer the subscription URL over pasting configs by hand.** Once you change a node (new IP, new SNI, add a node), clients pick it up on the next refresh; with pasted configs you would touch every device.

---

## Which clients support AnyReality (the default)

- **Supports AnyReality**: sing-box official apps (SFA Android / SFI iOS / SFM macOS), Karing, Hiddify (recent versions), NekoBox / nekoray (recent versions). These import the `profile.json` returned by the default subscription directly.
- **Legacy VLESS + Vision only**: Clash Verge / Verge Rev, mihomo / Clash.Meta, Stash, and Shadowrocket via a Clash subscription. **Clash / mihomo do not support AnyReality.** To use these clients, deploy the server with `--protocol vless-vision` (the subscription then returns `profile.yaml`).

---

## Minimum supported client versions (legacy vless-vision path)

> The table below is for the legacy `--protocol vless-vision` deployment (Clash-family clients). For the default AnyReality path, see "Which clients support AnyReality" above and "sing-box clients" below.

| Client | Platform | Min version | Reality | xtls-rprx-vision | Usage card |
|---|---|---|---|---|---|
| v2rayN | Windows | 6.0+ | ✓ | ✓ | ✓ |
| Clash Verge / Verge Rev | Win/Mac/Linux | 1.4+ | ✓ | ✓ | ✓ |
| Stash | iOS/macOS | 2.5+ | ✓ | ✓ | ✓ |
| sing-box client | All | 1.7+ | ✓ | ✓ | partial |
| Hiddify | All | 2.0+ | ✓ | ✓ | ✓ |
| Streisand | iOS | 2024+ | ✓ | ✓ | ✓ |
| Shadowrocket | iOS | 2.2+ | ✓ | ✓ | ✓ |
| v2rayNG | Android | 1.8+ | ✓ | ✓ | ✓ |
| NekoBox | Android | 1.3+ | ✓ | ✓ | ✓ |

⚠️ Older Clash for Windows and ClashX do **not** support Reality. Switch to a Verge fork or Stash.

---

## Windows · v2rayN

1. Download latest [v2rayN](https://github.com/2dust/v2rayN/releases)
2. Open → `Subscriptions` → `Subscription settings` → `Add`
3. Fill in:
   - Remarks: `anyreality-resi-stack`
   - URL: your subscription URL (`http://your-server/your-token`)
4. OK → right-click a node → `Subscription` → `Update`
5. Select node → `Ctrl+T` to test latency
6. System proxy → `Set system proxy automatically`

---

## macOS · Clash Verge Rev

1. Download [Clash Verge Rev](https://github.com/clash-verge-rev/clash-verge-rev/releases)
2. Install and open → `Profiles` tab
3. Paste subscription URL → `Download`
4. Select the new profile → enable
5. Top bar → `Outbound Mode` → `Rule`
6. System proxy: menu bar icon → `System Proxy` on

---

## iOS · Stash (recommended, paid)

1. App Store: install Stash
2. Open → `Profiles` → top-right `+` → `URL` → paste subscription URL
3. Wait for download → select profile → enable
4. Home → drag the bottom switch to start the VPN

---

## iOS · Shadowrocket (paid, not available on CN App Store)

1. Copy the `vless://` link to clipboard
2. Open Shadowrocket → home → top-right `+` — it auto-detects the clipboard
3. Or: `Server` tab → top-right `+` → `Subscribe` → paste subscription URL

---

## Android · v2rayNG / NekoBox

1. Install the latest v2rayNG or NekoBox
2. Top-right `+` → `Import config from clipboard` (paste `vless://`)
   - Or: `Settings` → `Subscription settings` → add URL → update
3. Select node → big play button at the bottom

> Note: the `vless://` link and v2rayNG here are the legacy vless-vision path. Under the default AnyReality, use a recent NekoBox / nekoray via subscription (which returns sing-box `profile.json`); v2rayNG does not support AnyReality.

---

## sing-box clients (the default AnyReality path, recommended)

The default AnyReality protocol is built for this path. The sing-box official apps (SFA / SFI / SFM), Karing, Hiddify, and NekoBox all import the sing-box `profile.json` returned by the default subscription directly.

**Subscription (recommended):**

1. Install the sing-box official app (or Karing / Hiddify / NekoBox) from App Store / Play / GitHub Releases
2. `Configuration` → New → choose the subscription-URL type and paste your subscription URL
3. Update the subscription → Home → start

The default subscription already returns full sing-box JSON (`profile.json`) — no manual schema conversion needed.

**Manual import of AnyReality credentials (when not using the subscription):**

`Configuration` → New → hand-write an `anytls` outbound with these fields (use your own real values):

- `type` = `anytls`
- `server` = your server IP
- `port` (`server_port`) = the inbound port
- `password` = `<ANYTLS_PASSWORD>` (AnyReality authenticates with a password — no UUID / flow)
- `tls.server_name` = `<SNI>`
- `tls.utls.fingerprint` = `chrome`
- `tls.reality.public_key` = `<REALITY_PUBLIC_KEY>`
- `tls.reality.short_id` = `<SHORT_ID>`

See `examples/single-node/sing-box-client-config.json` for a complete reference config.

---

## Confirm the client is actually using your node

Visit [https://ipinfo.io](https://ipinfo.io) in a browser. You should see:

- IP = your VPS's public IP
- ASN tagged with your VPS's ISP
- Geolocation = your VPS's city

If you see your real local IP, the client isn't routing through the proxy. Check:

- System proxy / TUN mode is on in the client
- Browser is using the system proxy (macOS/Linux Firefox doesn't follow system proxy by default — set manually)
- Client rules haven't routed this domain to DIRECT

---

## Confirm OpenAI/ChatGPT works (the residential IP's value proposition)

```bash
curl -i https://api.openai.com/v1/models
```

Expect `HTTP/2 401` (no API key → 401, **which means OpenAI accepted your IP**). If you see `403 Country, region, or territory not supported`, OpenAI rejected your exit IP — usually means the IP is classified as non-residential or is on a blocklist.

---

## Client import for dual-node

After deploying dual-node, the config returned by the subscription URL (sing-box `profile.json` under the default AnyReality, or Clash `profile.yaml` under legacy vless-vision) already contains **both nodes + smart routing rules**. The import flow is identical to single-node — **no additional configuration required**.

After import, the client shows:

- 2 nodes (e.g. `US-Resi-01` and `US-DC-01`)
- 3 proxy groups: `RESI`, `DC`, `AUTO`
- A pre-written ruleset (TG → DC, OpenAI → RESI, others → AUTO)

To override a specific rule, edit the client's "ruleset" directly — no need to touch the server.

---

## Things go wrong?

- First deployment and not sure where to start → [BEGINNER_GUIDE.md](BEGINNER_GUIDE.md)
- Card doesn't show traffic → [TROUBLESHOOTING.md](TROUBLESHOOTING.md), "Subscription URL works but no usage card"
- Client can't connect → [TROUBLESHOOTING.md](TROUBLESHOOTING.md), "Client cannot connect"
- TG uploads slow → [DUAL-NODE.md](DUAL-NODE.md), or [TROUBLESHOOTING.md](TROUBLESHOOTING.md), "Telegram / Discord"
