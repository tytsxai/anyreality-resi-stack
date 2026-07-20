from __future__ import annotations

import importlib.util
import os
import sys
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]


def load_module(filename: str, alias: str):
    os.environ.setdefault("TOKEN", "test-token")
    spec = importlib.util.spec_from_file_location(alias, REPO_ROOT / "subscription" / filename)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[alias] = module
    spec.loader.exec_module(module)
    return module


class ContentDispositionTest(unittest.TestCase):
    """Clients that cannot parse Content-Disposition invent a numeric profile
    id instead of using the real filename, so both the plain ASCII form and the
    RFC 5987 encoded form must always be present."""

    def setUp(self) -> None:
        self.leaf = load_module("leaf_server.py", "leaf_cd_under_test")
        self.aggregator = load_module("aggregator_server.py", "aggregator_cd_under_test")

    def test_ascii_filename_has_both_forms(self) -> None:
        value = self.leaf.content_disposition_for("profile.json")
        self.assertEqual(
            value,
            "attachment; filename=\"profile.json\"; filename*=UTF-8''profile.json",
        )

    def test_non_ascii_filename_is_percent_encoded(self) -> None:
        value = self.leaf.content_disposition_for("香港节点.json")
        self.assertIn("filename*=UTF-8''%E9%A6%99%E6%B8%AF", value)
        # The ASCII fallback must stay pure ASCII or the header is unsendable.
        head = value.split(";")[1]
        head.encode("ascii")

    def test_quote_cannot_escape_ascii_form(self) -> None:
        value = self.leaf.content_disposition_for('a"b.json')
        self.assertNotIn('"a"b.json"', value)
        self.assertIn('filename="a_b.json"', value)

    def test_aggregator_matches_leaf(self) -> None:
        self.assertEqual(
            self.aggregator.content_disposition_for("profile.json"),
            self.leaf.content_disposition_for("profile.json"),
        )


if __name__ == "__main__":
    unittest.main()
