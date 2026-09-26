#!/usr/bin/env python3
"""App Store Connect check and apply tool.

Sub-commands:
  check   Read-only. Prints PASS, MISSING, INFO and MANUAL lines for what is
          still open before the app can go to App Review.
  apply   Writes what AppStore/listing.json and the flags say. Idempotent.
          Never submits for review and never creates a review submission.

Credentials come from the environment: ASC_API_KEY_ID, ASC_API_ISSUER_ID,
ASC_API_KEY_P8_PATH (path to the .p8 file) and APP_BUNDLE_ID. The optional
REVIEW_CONTACT_FIRST_NAME, REVIEW_CONTACT_LAST_NAME, REVIEW_CONTACT_PHONE and
REVIEW_CONTACT_EMAIL feed the App Review contact details.

The output is public CI output. Every line goes through Out, which removes
registered secret values and anything that looks like an id, an email, a phone
number or a token. Identifiers, contact details and request bodies are never
printed.

Python 3.11, standard library plus `cryptography` for the ES256 signature.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import re
import struct
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

API_HOST = "api.appstoreconnect.apple.com"
API_BASE = "https://" + API_HOST
JWT_LIFETIME_SECONDS = 600  # Apple allows up to 20 minutes. Stay within 10.
JWT_REFRESH_MARGIN = 60
DEFAULT_TIMEOUT = 60
DEFAULT_DEADLINE = 1500
MAX_ATTEMPTS = 5
MAX_PAGES = 100

KEY_ID_RE = re.compile(r"^[A-Z0-9]{10}$")
ISSUER_ID_RE = re.compile(
    r"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$")
BUNDLE_ID_RE = re.compile(r"^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$")

REVIEW_CONTACT_ENV = (
    "REVIEW_CONTACT_FIRST_NAME",
    "REVIEW_CONTACT_LAST_NAME",
    "REVIEW_CONTACT_PHONE",
    "REVIEW_CONTACT_EMAIL",
)


# ---------------------------------------------------------------- errors ----

class AscError(Exception):
    """The API answered with an HTTP error status."""

    def __init__(self, status, errors=None, method="", path=""):
        super().__init__("HTTP %s" % status)
        self.status = status
        self.errors = errors or []
        self.method = method
        self.path = path

    def describe(self):
        parts = ["HTTP %s" % self.status]
        for err in self.errors[:3]:
            if not isinstance(err, dict):
                continue
            bits = [str(err.get(k)) for k in ("code", "title", "detail") if err.get(k)]
            if bits:
                parts.append(" ".join(bits))
        return " | ".join(parts)


class NetworkError(Exception):
    """The API could not be reached, or the global deadline passed."""


class ConfigError(Exception):
    """Credentials or input are missing or malformed."""


# ------------------------------------------------------------- sanitising ---

_SANITISERS = (
    (re.compile(r"eyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]*"), "<token>"),
    (re.compile(r"[A-Za-z0-9._%+-]+@(?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,}"), "<email>"),
    (re.compile(r"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\b"), "<id>"),
    (re.compile(r"\b[0-9A-Fa-f]{16,}\b"), "<id>"),
    (re.compile(r"\+\d[\d ()-]{7,}\d"), "<phone>"),
    (re.compile(r"\b\d{8,}\b"), "<id>"),
    (re.compile(r"\b(?=[A-Z0-9]{10}\b)(?=[A-Z]*\d)(?=\d*[A-Z])[A-Z0-9]{10}\b"), "<id>"),
    (re.compile(r"(?<![A-Za-z0-9_=+/-])(?=[A-Za-z0-9_=+/-]*\d)[A-Za-z0-9_=+/-]{24,}(?![A-Za-z0-9_=+/-])"), "<id>"),
)
MIN_SECRET_LEN = 3


class Out:
    """Central output. Nothing reaches stdout or the step summary except through here."""

    def __init__(self, stream=None, secrets=()):
        self.stream = stream if stream is not None else sys.stdout
        self.secrets = set()
        self.lines = []
        for value in secrets:
            self.add_secret(value)

    def add_secret(self, value):
        if not value:
            return
        value = str(value).strip()
        if len(value) >= MIN_SECRET_LEN:
            self.secrets.add(value)
        digits = re.sub(r"\D", "", value)
        if len(digits) >= 6:
            self.secrets.add(digits)

    def clean(self, text):
        text = str(text)
        for value in sorted(self.secrets, key=len, reverse=True):
            text = text.replace(value, "***")
        for pattern, repl in _SANITISERS:
            text = pattern.sub(repl, text)
        return text

    def raw(self, text=""):
        text = self.clean(text)
        self.lines.append(text)
        print(text, file=self.stream)
        self.stream.flush()

    def line(self, kind, item, text=""):
        if text:
            self.raw("%s %s: %s" % (kind, item, text))
        else:
            self.raw("%s %s" % (kind, item))

    def write_summary(self, title, path=None):
        path = path or os.environ.get("GITHUB_STEP_SUMMARY")
        if not path:
            return
        body = ["## " + self.clean(title), "", "```text"] + self.lines + ["```", ""]
        with open(path, "a", encoding="utf-8") as fh:
            fh.write("\n".join(body))


def mask_for_ci(value, out=None):
    """Ask the GitHub runner to mask a derived value and register it locally."""
    value = str(value or "")
    if len(value) < 6:
        return
    if out is not None:
        out.add_secret(value)
    if os.environ.get("GITHUB_ACTIONS") == "true":
        print("::add-mask::" + value, flush=True)


# -------------------------------------------------------------------- JWT ---

def _b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def _crypto():
    try:
        from cryptography.hazmat.primitives import hashes, serialization
        from cryptography.hazmat.primitives.asymmetric import ec
        from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature
    except ImportError as exc:  # pragma: no cover
        raise ConfigError("the cryptography package is not installed") from exc
    return hashes, serialization, ec, decode_dss_signature


def load_private_key(path):
    _hashes, serialization, ec, _dss = _crypto()
    try:
        with open(path, "rb") as fh:
            data = fh.read()
        key = serialization.load_pem_private_key(data, password=None)
    except (OSError, ValueError, TypeError) as exc:
        raise ConfigError("the API private key file could not be read as a PEM key") from exc
    if not isinstance(key, ec.EllipticCurvePrivateKey) or key.curve.name != "secp256r1":
        raise ConfigError("the API private key is not an ES256 (P-256) key")
    return key


def make_jwt(key_id, issuer_id, private_key, now, lifetime=JWT_LIFETIME_SECONDS):
    hashes, _ser, ec, decode_dss_signature = _crypto()
    header = {"alg": "ES256", "kid": key_id, "typ": "JWT"}
    claims = {
        "iss": issuer_id,
        "iat": int(now),
        "exp": int(now) + int(lifetime),
        "aud": "appstoreconnect-v1",
    }
    signing_input = "%s.%s" % (
        _b64url(json.dumps(header, separators=(",", ":")).encode()),
        _b64url(json.dumps(claims, separators=(",", ":")).encode()),
    )
    der = private_key.sign(signing_input.encode("ascii"), ec.ECDSA(hashes.SHA256()))
    r, s = decode_dss_signature(der)
    signature = r.to_bytes(32, "big") + s.to_bytes(32, "big")
    return signing_input + "." + _b64url(signature)


# ---------------------------------------------------------------- transport -

class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


_OPENER = urllib.request.build_opener(_NoRedirect)


def urllib_transport(method, url, headers, body, timeout):
    """Return (status, headers, body). HTTP errors are returned, not raised."""
    request = urllib.request.Request(url, data=body, method=method, headers=headers)
    try:
        with _OPENER.open(request, timeout=timeout) as resp:
            return resp.status, dict(resp.headers), resp.read()
    except urllib.error.HTTPError as err:
        try:
            payload = err.read()
        finally:
            err.close()
        return err.code, dict(err.headers), payload


def parse_errors(payload):
    try:
        doc = json.loads(payload.decode("utf-8")) if payload else {}
    except (ValueError, UnicodeDecodeError):
        return []
    errors = doc.get("errors") if isinstance(doc, dict) else None
    return errors if isinstance(errors, list) else []


class Api:
    """Signed JSON:API client with retries, pagination and a global deadline."""

    def __init__(self, key_id, issuer_id, private_key, transport=None, sleep=time.sleep,
                 clock=time.time, timeout=DEFAULT_TIMEOUT, max_attempts=MAX_ATTEMPTS,
                 deadline=DEFAULT_DEADLINE):
        self.key_id = key_id
        self.issuer_id = issuer_id
        self.private_key = private_key
        self.transport = transport or urllib_transport
        self.sleep = sleep
        self.clock = clock
        self.timeout = timeout
        self.max_attempts = max_attempts
        self.deadline_at = clock() + deadline
        self._token = None
        self._token_exp = 0

    # -- auth
    def token(self):
        now = self.clock()
        if self._token is None or now >= self._token_exp - JWT_REFRESH_MARGIN:
            self._token = make_jwt(self.key_id, self.issuer_id, self.private_key, now)
            self._token_exp = int(now) + JWT_LIFETIME_SECONDS
        return self._token

    # -- core request
    def _send(self, method, url, headers, body, retry_label):
        attempt = 0
        while True:
            attempt += 1
            if self.clock() > self.deadline_at:
                raise NetworkError("the global time limit passed")
            timeout = max(1, min(self.timeout, self.deadline_at - self.clock()))
            try:
                status, resp_headers, payload = self.transport(method, url, headers, body, timeout)
            except (urllib.error.URLError, OSError, TimeoutError) as exc:
                if attempt >= self.max_attempts:
                    raise NetworkError("the API could not be reached (%s)" % type(exc).__name__) from None
                self.sleep(self._backoff(attempt, None))
                continue
            if status == 429 or status >= 500:
                if attempt >= self.max_attempts:
                    raise AscError(status, parse_errors(payload), method, retry_label)
                self.sleep(self._backoff(attempt, resp_headers))
                continue
            return status, resp_headers, payload

    @staticmethod
    def _backoff(attempt, headers):
        if headers:
            for name, value in headers.items():
                if name.lower() == "retry-after":
                    try:
                        return max(0, min(60, float(value)))
                    except ValueError:
                        break
        return min(30, 2 ** (attempt - 1))

    def request(self, method, path, params=None, body=None):
        if path.startswith("https://"):
            if urllib.parse.urlsplit(path).hostname != API_HOST:
                raise ConfigError("refusing to send credentials to another host")
            url = path
        else:
            url = API_BASE + path
        if params:
            query = urllib.parse.urlencode(params, safe="[],")
            url += ("&" if "?" in url else "?") + query
        headers = {
            "Authorization": "Bearer " + self.token(),
            "Accept": "application/json",
        }
        data = None
        if body is not None:
            data = json.dumps(body).encode("utf-8")
            headers["Content-Type"] = "application/json"
        label = urllib.parse.urlsplit(url).path
        status, _h, payload = self._send(method, url, headers, data, label)
        if 200 <= status < 300:
            if not payload:
                return {}
            try:
                return json.loads(payload.decode("utf-8"))
            except (ValueError, UnicodeDecodeError):
                raise AscError(status, [{"title": "response is not JSON"}], method, label) from None
        raise AscError(status, parse_errors(payload), method, label)

    def get(self, path, params=None):
        return self.request("GET", path, params=params)

    def post(self, path, body):
        return self.request("POST", path, body=body)

    def patch(self, path, body):
        return self.request("PATCH", path, body=body)

    def delete(self, path):
        return self.request("DELETE", path)

    def get_all(self, path, params=None, max_pages=MAX_PAGES):
        """Follow links.next. Returns (data list, included list)."""
        data, included = [], []
        page = self.get(path, params)
        for _ in range(max_pages):
            chunk = page.get("data")
            if isinstance(chunk, list):
                data.extend(chunk)
            elif isinstance(chunk, dict):
                data.append(chunk)
            included.extend(page.get("included") or [])
            nxt = (page.get("links") or {}).get("next")
            if not nxt:
                break
            page = self.request("GET", nxt)
        return data, included

    def put_part(self, method, url, headers, data):
        """Send one upload part to the URL that Apple returned. No API credentials."""
        if not url.startswith("https://"):
            raise ConfigError("an upload operation did not use https")
        status, _h, payload = self._send(method, url, dict(headers), data, "upload")
        if not 200 <= status < 300:
            raise AscError(status, parse_errors(payload), method, "upload")


# ---------------------------------------------------------------- CLI -------

def read_env(out):
    key_id = os.environ.get("ASC_API_KEY_ID", "").strip()
    issuer = os.environ.get("ASC_API_ISSUER_ID", "").strip()
    bundle = os.environ.get("APP_BUNDLE_ID", "").strip()
    key_path = os.environ.get("ASC_API_KEY_P8_PATH", "").strip()
    for value in (key_id, issuer, bundle):
        out.add_secret(value)
    problems = []
    if not KEY_ID_RE.match(key_id):
        problems.append("ASC_API_KEY_ID is missing or has the wrong shape")
    if not ISSUER_ID_RE.match(issuer):
        problems.append("ASC_API_ISSUER_ID is missing or has the wrong shape")
    if not BUNDLE_ID_RE.match(bundle):
        problems.append("APP_BUNDLE_ID is missing or has the wrong shape")
    if not key_path or not os.path.isfile(key_path):
        problems.append("ASC_API_KEY_P8_PATH does not point to a file")
    if problems:
        raise ConfigError("; ".join(problems))
    return key_id, issuer, bundle, key_path


def build_parser():
    parser = argparse.ArgumentParser(prog="asc_tool.py", description=__doc__.split("\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    chk = sub.add_parser("check", help="read-only report of what is still missing")
    chk.add_argument("--listing", default=None, help="path to listing.json (optional for check)")
    app = sub.add_parser("apply", help="write listing data, build and screenshots")
    app.add_argument("--listing", default="AppStore/listing.json")
    return parser


def main(argv=None, transport=None, sleep=time.sleep, clock=time.time, stream=None):
    args = build_parser().parse_args(argv)
    out = Out(stream=stream)
    try:
        key_id, issuer, bundle, key_path = read_env(out)
        key = load_private_key(key_path)
        api = Api(key_id, issuer, key, transport=transport, sleep=sleep, clock=clock)
    except ConfigError as exc:
        out.raw("ERROR configuration: %s" % exc)
        return 2
    out.raw("ERROR %s is not implemented yet" % args.command)
    return 2


if __name__ == "__main__":
    sys.exit(main())
