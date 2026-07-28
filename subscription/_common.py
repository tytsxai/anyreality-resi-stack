#!/usr/bin/env python3
"""Shared plumbing for the leaf and aggregator subscription servers.

The two servers differ in exactly two ways: where the usage number comes from
(kernel counters vs. a polled upstream) and what their ``/status`` JSON says.
Everything else — environment parsing, path safety, content types, the
``Content-Disposition`` shape, the HTTP server, the request routing — was
duplicated line-for-line, which is how the two copies drifted apart (different
``ensure_ascii`` on the health payload, for one).

This module holds the common half. It is deployed alongside the two server
scripts in the same directory, so a plain ``import _common`` resolves via
``sys.path[0]`` with no packaging, no ``PYTHONPATH``, and no dependencies —
the zero-dependency property of this package is deliberate and preserved.
"""

from __future__ import annotations

import json
import logging
import os
import ssl
import threading
from contextlib import suppress
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import NoReturn
from urllib.parse import quote, unquote

log = logging.getLogger("subscription")

CONTENT_TYPES = {
    ".yaml": "text/yaml; charset=utf-8",
    ".yml": "text/yaml; charset=utf-8",
    ".json": "application/json; charset=utf-8",
    ".txt": "text/plain; charset=utf-8",
}


# ── Configuration parsing ────────────────────────────────────────────────
# Both services run under `Restart=always`. A typo in the EnvironmentFile used
# to surface as a bare KeyError/ValueError traceback in an endless crash loop
# with no indication of which unit or which variable was at fault. Parse
# defensively instead and exit 2 with the offending variable named.
_UNIT_HINT = "the subscription service"


def set_unit_hint(unit: str) -> None:
    """Name the systemd unit so configuration errors are directly actionable."""
    global _UNIT_HINT
    _UNIT_HINT = unit


def config_error(message: str) -> NoReturn:
    log.error("configuration error: %s", message)
    log.error("check the EnvironmentFile, then: systemctl restart %s", _UNIT_HINT)
    raise SystemExit(2)


def env_str(name: str, default: str | None = None) -> str:
    value = os.environ.get(name, default)
    if value is None or not value.strip():
        config_error(f"{name} is required but empty or unset")
    return value


def env_int(name: str, default: str, minimum: int | None = None,
            maximum: int | None = None) -> int:
    raw = os.environ.get(name, default).strip()
    try:
        value = int(raw)
    except ValueError:
        config_error(f"{name} must be an integer, got: {raw!r}")
    if minimum is not None and value < minimum:
        config_error(f"{name} must be >= {minimum}, got: {value}")
    if maximum is not None and value > maximum:
        config_error(f"{name} must be <= {maximum}, got: {value}")
    return value


def env_float(name: str, default: str, minimum: float | None = None) -> float:
    raw = os.environ.get(name, default).strip()
    try:
        value = float(raw)
    except ValueError:
        config_error(f"{name} must be a number, got: {raw!r}")
    if minimum is not None and value < minimum:
        config_error(f"{name} must be >= {minimum}, got: {value}")
    return value


def env_bool(name: str, default: str) -> bool:
    raw = os.environ.get(name, default).strip().lower()
    if raw in {"1", "true", "yes", "on"}:
        return True
    if raw in {"0", "false", "no", "off"}:
        return False
    config_error(f"{name} must be true/false, got: {raw!r}")


# ── Filesystem helpers ───────────────────────────────────────────────────
def safe_target_path(target: str, file_dir: Path, default_target: str) -> Path | None:
    """Resolve ``target`` inside ``file_dir`` while rejecting traversal.

    Only bare, non-hidden filenames are accepted. Note that pathlib does NOT
    normalise ``..`` away — ``Path("..").name`` is ``".."`` — so the separator
    check alone would happily return ``file_dir/..``. Today that resolves to a
    directory and fails the caller's ``is_file()`` guard, but relying on that is
    one refactor away from a real traversal, so reject the dot entries here.
    """
    target = target.strip("/")
    if not target:
        target = default_target
    if target.startswith(".") or target != Path(target).name:
        return None
    return file_dir / target


def content_type_for(path: Path) -> str:
    return CONTENT_TYPES.get(path.suffix.lower(), "application/octet-stream")


def content_disposition_for(name: str) -> str:
    """Build an RFC 6266 / RFC 5987 Content-Disposition value.

    Clients that cannot parse the header fall back to inventing a numeric id
    for the imported profile, so emit BOTH forms: a plain ASCII ``filename=``
    that every client understands, and a percent-encoded ``filename*=`` that
    carries the exact (possibly non-ASCII) name for clients that do.
    """
    ascii_name = name.encode("ascii", "replace").decode("ascii").replace('"', "_")
    return f"attachment; filename=\"{ascii_name}\"; filename*=UTF-8''{quote(name, safe='')}"


def atomic_write_json(path: Path, payload: dict) -> None:
    """Write ``payload`` to ``path`` atomically.

    The temp file is created alongside the target (never in /tmp) so the final
    ``replace`` is a same-filesystem rename, and is uniquely named per
    process/thread so concurrent writers cannot clobber each other's temp file.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.{os.getpid()}.{threading.get_ident()}.tmp")
    try:
        tmp.write_text(json.dumps(payload, ensure_ascii=True, sort_keys=True), encoding="utf-8")
        tmp.replace(path)
    finally:
        with suppress(FileNotFoundError):
            tmp.unlink()


# ── HTTP ─────────────────────────────────────────────────────────────────
class SubscriptionHTTPServer(ThreadingHTTPServer):
    """Threaded server with a per-connection timeout and optional TLS.

    ``request_timeout`` keeps slow or abandoned clients from pinning a worker
    thread forever. ``ssl_context`` is set when TLS_CERT_FILE is configured; a
    failed handshake raises inside ``get_request``, which ``serve_forever``
    already treats as a dropped connection, so a probe cannot take the server
    down.
    """

    daemon_threads = True
    allow_reuse_address = True
    request_queue_size = 64
    request_timeout = 10.0
    ssl_context: ssl.SSLContext | None = None

    def get_request(self):  # type: ignore[no-untyped-def]
        sock, addr = super().get_request()
        sock.settimeout(self.request_timeout)
        if self.ssl_context is not None:
            sock = self.ssl_context.wrap_socket(sock, server_side=True)
        return sock, addr


def build_ssl_context() -> ssl.SSLContext | None:
    """Build a TLS context from TLS_CERT_FILE / TLS_KEY_FILE, or None.

    The subscription URL is a credential — the profile behind it contains the
    node password — so serving it over plain HTTP exposes it to anyone on the
    path. Terminating TLS here needs a certificate for a real hostname, which
    an IP-only deployment does not have; hence opt-in rather than default.
    """
    cert = os.environ.get("TLS_CERT_FILE", "").strip()
    key = os.environ.get("TLS_KEY_FILE", "").strip()
    if not cert and not key:
        return None
    if not cert or not key:
        config_error("TLS_CERT_FILE and TLS_KEY_FILE must both be set, or neither")
    for label, path in (("TLS_CERT_FILE", cert), ("TLS_KEY_FILE", key)):
        if not Path(path).is_file():
            config_error(f"{label} does not exist or is not a file: {path}")

    context = ssl.create_default_context(ssl.Purpose.CLIENT_AUTH)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    try:
        context.load_cert_chain(certfile=cert, keyfile=key)
    except (ssl.SSLError, OSError) as exc:
        config_error(f"cannot load TLS certificate/key ({exc})")
    log.info("TLS enabled using %s", cert)
    return context


def serve(host: str, port: int, handler: type[BaseHTTPRequestHandler],
          request_timeout: float) -> NoReturn:
    """Bind and serve forever, turning a failed bind into a named config error."""
    SubscriptionHTTPServer.request_timeout = request_timeout
    SubscriptionHTTPServer.ssl_context = build_ssl_context()
    try:
        server = SubscriptionHTTPServer((host, port), handler)
    except OSError as exc:
        config_error(f"cannot bind {host}:{port} ({exc}) — port busy or missing privileges")
    scheme = "https" if SubscriptionHTTPServer.ssl_context else "http"
    log.info("listening on %s://%s:%s", scheme, host, port)
    server.serve_forever()
    raise SystemExit(0)


class BaseSubscriptionHandler(BaseHTTPRequestHandler):
    """Routing shared by both servers.

    Subclasses provide the two things that actually differ:
    ``usage_bytes()`` and ``status_payload()``. Everything below — the token
    check, path safety, headers, HEAD handling — stays in one place so the two
    deployments cannot drift apart again.
    """

    # Set by the concrete server module before the server starts.
    token = ""
    file_dir = Path("/etc/anyreality-resi-stack/files")
    default_target = "profile.yaml"
    profile_title = ""
    update_interval_hours = "24"
    total_bytes = 0
    expire_ts = 0

    def usage_bytes(self) -> int:
        raise NotImplementedError

    def status_payload(self) -> dict:
        raise NotImplementedError

    def do_GET(self) -> None:  # noqa: N802
        self.handle_request(send_body=True)

    def do_HEAD(self) -> None:  # noqa: N802
        self.handle_request(send_body=False)

    def handle_request(self, send_body: bool) -> None:
        raw_path = unquote(self.path.split("?", 1)[0]).strip("/")

        if raw_path == "healthz":
            self.send_json(HTTPStatus.OK, {"ok": True, "service": self.profile_title}, send_body)
            return

        parts = raw_path.split("/", 1) if raw_path else []
        if not parts or parts[0] != self.token:
            self.send_error(HTTPStatus.NOT_FOUND)
            return

        target = self.default_target if len(parts) == 1 or not parts[1] else parts[1]
        if target == "status":
            self.send_json(HTTPStatus.OK, self.status_payload(), send_body)
            return

        file_path = safe_target_path(target, self.file_dir, self.default_target)
        if file_path is None or not file_path.is_file():
            self.send_error(HTTPStatus.NOT_FOUND)
            return

        body = file_path.read_bytes()
        used_bytes = self.usage_bytes()

        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", content_type_for(file_path))
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Profile-Title", self.profile_title)
        self.send_header("Profile-Update-Interval", self.update_interval_hours)
        self.send_header("Content-Disposition", content_disposition_for(file_path.name))
        self.send_header(
            "Subscription-Userinfo",
            f"upload=0; download={used_bytes}; total={self.total_bytes}; "
            f"expire={self.expire_ts}",
        )
        self.end_headers()
        if send_body:
            self.wfile.write(body)

    def send_json(self, status: HTTPStatus, payload: dict, send_body: bool) -> None:
        body = json.dumps(payload, ensure_ascii=True).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if send_body:
            self.wfile.write(body)

    def log_message(self, fmt: str, *args) -> None:  # noqa: A003
        log.info("%s - %s", self.address_string(), fmt % args)
