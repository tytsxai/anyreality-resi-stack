"""Routing rules that are present but silently ineffective.

Every assertion here maps to a failure mode where `sing-box check` passes, the
service is active, the log is clean — and the rule still does nothing. Those are
invisible to any "is the key present?" test, so each one checks **relative
order**, which is what actually decides whether a rule fires.

1. `action: resolve` must precede IP-based rules (`geoip-*` rule sets,
   `ip_cidr`). Clients send *domains*; sing-box does not resolve them just to
   evaluate an IP rule, and configuring `route.default_domain_resolver` does
   NOT change that — it only says *which* resolver to use once something asks.
   Verified empirically on sing-box 1.13.14: with the resolve rule removed, a
   `geoip-cn` rule never matched a domain request; re-adding it made the same
   request match immediately.

2. `challenges.cloudflare.com` must be routed to the node *before* the resolve
   rule. Cloudflare serves its challenge widget from an AAAA-only host
   (`brunhild.challenges.cloudflare.com`); under the client's `ipv4_only`
   strategy, resolving it yields an empty result and the CAPTCHA page spins
   forever. Sending it upstream by domain avoids resolving it client-side.

3. The server DNS config must exempt that same suffix from `ipv4_only`.
"""

from __future__ import annotations

import json
import re
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
CLIENT_TEMPLATES = [
    REPO_ROOT / "templates" / "singbox-client" / "client-single.json.tmpl",
    REPO_ROOT / "templates" / "singbox-client" / "client-dual.json.tmpl",
]
SERVER_DNS = REPO_ROOT / "templates" / "singbox" / "05_dns.json"
CF_CHALLENGE_SUFFIX = "challenges.cloudflare.com"


def render(path: Path) -> dict:
    """Fill @@PLACEHOLDER@@ tokens so the template parses as JSON."""
    text = path.read_text(encoding="utf-8")
    text = re.sub(r"@@[A-Z0-9_]*PORT@@", "443", text)  # numeric position
    text = re.sub(r"@@[A-Z0-9_]+@@", "PLACEHOLDER", text)  # all inside quotes
    return json.loads(text)


def first_index(rules: list[dict], predicate) -> int | None:
    return next((i for i, r in enumerate(rules) if predicate(r)), None)


class ClientRuleOrderTest(unittest.TestCase):
    def test_templates_are_valid_json(self) -> None:
        for path in CLIENT_TEMPLATES:
            with self.subTest(template=path.name):
                self.assertIsInstance(render(path), dict)

    def test_resolve_precedes_ip_based_rules(self) -> None:
        """Without this, geoip-cn / ip_cidr rules never match domain traffic."""
        for path in CLIENT_TEMPLATES:
            with self.subTest(template=path.name):
                rules = render(path)["route"]["rules"]
                resolve_at = first_index(rules, lambda r: r.get("action") == "resolve")
                self.assertIsNotNone(
                    resolve_at,
                    f"{path.name}: no 'action: resolve' rule — every IP-based rule "
                    "below it silently never matches domain traffic",
                )

                def is_ip_rule(r: dict) -> bool:
                    rs = r.get("rule_set")
                    rs_names = [rs] if isinstance(rs, str) else (rs or [])
                    return "ip_cidr" in r or any("geoip" in n for n in rs_names)

                first_ip_rule = first_index(rules, is_ip_rule)
                if first_ip_rule is None:
                    self.skipTest("template has no IP-based rules")
                self.assertLess(
                    resolve_at,
                    first_ip_rule,
                    f"{path.name}: 'action: resolve' is at index {resolve_at} but the "
                    f"first IP-based rule is at {first_ip_rule}. The IP rule cannot "
                    "match domain traffic and is effectively dead.",
                )

    def test_cf_challenge_routed_before_resolve(self) -> None:
        """AAAA-only host must bypass the client's ipv4_only resolution."""
        for path in CLIENT_TEMPLATES:
            with self.subTest(template=path.name):
                rules = render(path)["route"]["rules"]
                chal_at = first_index(
                    rules, lambda r: CF_CHALLENGE_SUFFIX in str(r.get("domain_suffix", ""))
                )
                self.assertIsNotNone(
                    chal_at,
                    f"{path.name}: no rule for {CF_CHALLENGE_SUFFIX}. Under ipv4_only "
                    "the CAPTCHA widget resolves to an empty result and the "
                    "verification page spins forever.",
                )
                resolve_at = first_index(rules, lambda r: r.get("action") == "resolve")
                if resolve_at is not None:
                    self.assertLess(
                        chal_at,
                        resolve_at,
                        f"{path.name}: the {CF_CHALLENGE_SUFFIX} rule must come before "
                        "'action: resolve', otherwise it gets resolved under ipv4_only "
                        "and yields an empty result.",
                    )

    def test_cf_challenge_does_not_go_direct(self) -> None:
        """Sending it direct defeats the point — it must traverse the node."""
        for path in CLIENT_TEMPLATES:
            with self.subTest(template=path.name):
                for rule in render(path)["route"]["rules"]:
                    if CF_CHALLENGE_SUFFIX in str(rule.get("domain_suffix", "")):
                        self.assertNotEqual(
                            rule.get("outbound"),
                            "direct",
                            f"{path.name}: {CF_CHALLENGE_SUFFIX} must go through the "
                            "node, not direct",
                        )


class ServerDnsTest(unittest.TestCase):
    def test_cf_challenge_exempt_from_ipv4_only(self) -> None:
        dns = json.loads(SERVER_DNS.read_text(encoding="utf-8"))["dns"]
        self.assertEqual(
            dns.get("strategy"),
            "ipv4_only",
            "global strategy changed; re-check whether the exemption below is still needed",
        )
        rules = dns.get("rules", [])
        match = next(
            (r for r in rules if CF_CHALLENGE_SUFFIX in str(r.get("domain_suffix", ""))),
            None,
        )
        self.assertIsNotNone(
            match,
            f"{SERVER_DNS.name}: global strategy is ipv4_only but there is no "
            f"exemption for {CF_CHALLENGE_SUFFIX}, whose widget host is AAAA-only. "
            "CAPTCHA pages will never complete.",
        )
        self.assertEqual(
            match.get("strategy"),
            "prefer_ipv4",
            "exemption must be prefer_ipv4: use A when present, fall back to AAAA",
        )
        # sing-box >=1.12 puts `strategy` on the DNS rule's action, not the server.
        self.assertEqual(match.get("action"), "route")


if __name__ == "__main__":
    unittest.main()
