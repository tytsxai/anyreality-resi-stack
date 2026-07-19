# Beginner Guide

This guide is for people deploying their first self-hosted proxy node. You do not need to write sing-box or Xray configs by hand. You only need SSH access to a VPS and the discipline to verify each step.

End state:

- sing-box + AnyTLS + REALITY (AnyReality, the default protocol) runs on your server
- your client imports a subscription URL
- your browser exits through the VPS IP
- OpenAI / ChatGPT connectivity works
- you know when dual-node routing is worth adding

## 1. Before you deploy

### VPS requirements

Minimum:

- Ubuntu 22.04+ / 24.04 LTS, or Debian 12+
- 1 vCPU, 512 MiB RAM, 10 GiB disk
- Public IPv4
- Ability to open `443/tcp`
- Ability to open `80/tcp` if you want the subscription URL

A residential-IP VPS is valuable because OpenAI, Anthropic, Netflix, banking sites, and similar services often treat residential egress with better reputation. A regular data-center VPS also works, but it will not give you that residential-IP advantage.

Avoid these for a first deployment:

- CentOS 7, Alpine, OpenWRT
- Docker-only or Kubernetes-only environments
- IPv6-only servers without public IPv4
- Servers where you cannot open `443/tcp`

### Local machine

You need a computer that can SSH to the server. macOS and Linux can use Terminal; Windows can use PowerShell, Windows Terminal, or Termius.

Have these ready:

```text
Server IP
root user or sudo user
SSH port, usually 22
```

## 2. SSH into the server

Replace the example IP with your own:

```bash
ssh root@YOUR_SERVER_IP
```

If SSH runs on a custom port:

```bash
ssh -p 2222 root@YOUR_SERVER_IP
```

Confirm the OS:

```bash
cat /etc/os-release | head -5
```

Continue if you see Ubuntu 22.04+, Ubuntu 24.04+, or Debian 12+.

## 3. Dry-run first

Run a dry-run first. It prints what the installer would do without changing system state:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/tytsxai/anyreality-resi-stack/main/install/install.sh) \
  --node-name "US-Resi-01" \
  --sni addons.mozilla.org \
  --with-subscription \
  --dry-run
```

Look for the expected phases:

- OS preflight
- sing-box install
- ANYTLS password / Reality key / subscription token generation (default AnyReality; legacy vless-vision generates a UUID)
- `443/tcp` service configuration
- subscription service on `80/tcp`
- UFW / fail2ban configuration
- systemd service enablement

You can omit `--with-subscription`, but beginners should keep it. A subscription URL is easier to import and refresh across clients.

## 4. Install for real

If the dry-run looks right, remove `--dry-run`:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/tytsxai/anyreality-resi-stack/main/install/install.sh) \
  --node-name "US-Resi-01" \
  --sni addons.mozilla.org \
  --with-subscription
```

The default install is **AnyReality (AnyTLS + REALITY)** — no extra flag needed. AnyReality authenticates with a password (`ANYTLS_PASSWORD`, stored in `/etc/anyreality-resi-stack/secrets.env`); there is no UUID or flow, and it still needs no domain or certificate.

If your client is **Clash-based** (Clash Verge Rev, etc.), note that Clash/mihomo **does not support AnyReality**. Reinstall with the legacy protocol by adding `--protocol vless-vision`:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/tytsxai/anyreality-resi-stack/main/install/install.sh) \
  --protocol vless-vision \
  --node-name "US-Resi-01" \
  --sni addons.mozilla.org \
  --with-subscription
```

At the end, the installer prints a completion card. Save:

- AnyReality (default): the `password=` and other AnyTLS credentials on the card; legacy vless-vision prints a `vless://...` link
- `Subscription URL: http://YOUR_SERVER_IP/YOUR_TOKEN`

Do not paste these into public issues, forums, or screenshots. They contain node credentials.

## 5. Verify on the server

Check sing-box:

```bash
systemctl is-active sing-box
ss -tlnp | grep ':443'
sing-box check -C /etc/sing-box/conf
```

If you enabled the subscription service:

```bash
curl -i http://127.0.0.1/healthz
curl -I http://YOUR_SERVER_IP/$(grep ^SUB_TOKEN /etc/anyreality-resi-stack/secrets.env | cut -d= -f2)
```

The `curl -I` response should include:

- `Profile-Title`
- `Profile-Update-Interval`
- `Subscription-Userinfo`

## 6. Import into a client

Prefer the subscription URL over pasting credentials manually. When you change IPs, rename nodes, or add dual-node routing, clients can refresh the subscription.

With the default AnyReality, the subscription returns a full **sing-box config (`profile.json`)**, so use a **sing-box-based client**:

- All platforms: the official sing-box app
- iOS / macOS / Android / Windows: Karing, Hiddify

If you installed with `--protocol vless-vision` (legacy) in step 4, the subscription returns a **Clash config (`profile.yaml`)**; only then use a Clash-based client:

- Windows: v2rayN
- macOS / Windows / Linux: Clash Verge Rev
- iOS / macOS: Stash
- iOS: Shadowrocket
- Android: v2rayNG / NekoBox

The subscription URL itself is unchanged in both cases: `http://<server>/<TOKEN>/`. Exact click paths are in [Client import](CLIENTS.md).

After importing, use:

- sing-box / Karing / Hiddify: VPN/TUN started
- Clash Verge / Stash: `Rule` mode
- v2rayN: system proxy enabled
- Mobile clients: VPN/TUN started

## 7. Verify the exit IP

Open this in a browser:

```text
https://ipinfo.io
```

You should see your VPS public IP, not your local home IP.

If you still see your local IP, check:

- system proxy or VPN mode is enabled
- the browser follows system proxy settings
- the imported node is selected
- Clash-style clients are in `Rule` or `Global`, not `Direct`

## 8. Verify OpenAI / ChatGPT connectivity

From your local machine, test through the client's local SOCKS port:

```bash
curl --proxy socks5h://127.0.0.1:7891 -i https://api.openai.com/v1/models
```

Without an API key, `HTTP/2 401` is expected. It means the OpenAI path is reachable but unauthenticated.

If you see `403 Country, region, or territory not supported`, OpenAI rejected the exit IP. Common causes:

- the VPS IP is not actually residential
- the region is unsupported
- the IP range is already blocked

That is not an installer bug; you need a different exit IP or provider.

## 9. When to add dual-node routing

Use the single-node setup for a few days first. Add dual-node routing only when you see symptoms like:

- Telegram photo/file uploads stuck on "sending"
- Discord voice quality is poor while normal browsing is fine
- OpenAI / Claude works well on residential IP, but messaging apps are slow

Dual-node routing means:

- OpenAI / Claude / Netflix / banking goes through the residential node
- Telegram / Discord goes through a data-center fallback node
- clients still import one subscription URL

See [Dual-node smart routing](DUAL-NODE.md).

## 10. Common mistakes

### The client does not support AnyReality / Reality

The default AnyReality (AnyTLS + REALITY) is only supported by sing-box-based clients; **Clash / mihomo does not support AnyReality**. To use a Clash-based client, reinstall with the legacy protocol via `--protocol vless-vision`.

Legacy vless-vision uses Reality, and old Clash for Windows and ClashX do not support Reality either. Use maintained clients such as Clash Verge Rev, Stash, v2rayN, v2rayNG, or NekoBox.

### Firewall ports are closed

Both the cloud security group and the server firewall must allow `443/tcp`. If you use the subscription service, also allow `80/tcp`.

### You leaked credentials in a screenshot

If you expose the AnyTLS password, `vless://` link, subscription URL, UUID, Reality private key, or token, rotate credentials or redeploy.

### fail2ban locked you out

See the fail2ban section in [Troubleshooting](TROUBLESHOOTING.md). Before enabling `--harden-ssh`, keep a backup SSH session open and verify key-based login.

## Next

- Full installer options: [Deployment](DEPLOYMENT.md)
- More client setup paths: [Client import](CLIENTS.md)
- Subscription and usage-card design: [Subscription server design](SUBSCRIPTION.md)
- Compare 3x-ui / x-ui / manual config: [Comparison](COMPARISON.md)
- Something broke: [Troubleshooting](TROUBLESHOOTING.md)
