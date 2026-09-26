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


# ------------------------------------------------------------ listing -------

LISTING_KEYS = (
    "locale", "name", "subtitle", "promotionalText", "description", "keywords",
    "whatsNew", "supportUrl", "marketingUrl", "privacyPolicyUrl", "copyright",
    "primaryCategory", "secondaryCategory", "contentRightsDeclaration",
    "ageRating", "reviewNotes", "reviewDemoRequired",
)
LIMITS = {
    "name": 30,
    "subtitle": 30,
    "promotionalText": 170,
    "keywords": 100,
    "description": 4000,
    "whatsNew": 4000,
    "reviewNotes": 4000,
}
URL_KEYS = ("supportUrl", "marketingUrl", "privacyPolicyUrl")
URL_LIMIT = 255
CONTENT_RIGHTS = ("DOES_NOT_USE_THIRD_PARTY_CONTENT", "USES_THIRD_PARTY_CONTENT")
LOCALE_RE = re.compile(r"^[a-z]{2,3}(-[A-Za-z0-9]{2,8})*$")
CATEGORY_RE = re.compile(r"^[A-Z][A-Z0-9_]*$")
ATTR_NAME_RE = re.compile(r"^[a-z][A-Za-z0-9]*$")


def validate_listing(doc):
    """Return a list of problems. An empty list means the listing is valid."""
    if not isinstance(doc, dict):
        return ["the listing must be a JSON object"]
    problems = []
    for key in LISTING_KEYS:
        if key not in doc:
            problems.append("%s: key is missing" % key)
    for key, limit in LIMITS.items():
        value = doc.get(key)
        if value is None or key not in doc:
            continue
        if not isinstance(value, str):
            problems.append("%s: must be a string" % key)
        elif len(value) > limit:
            problems.append("%s: %d characters, the limit is %d" % (key, len(value), limit))
    for key in URL_KEYS:
        value = doc.get(key)
        if value in (None, "") or key not in doc:
            continue
        if not isinstance(value, str) or not re.match(r"^https?://[^\s/]+\S*$", value):
            problems.append("%s: must be an http or https URL" % key)
        elif len(value) > URL_LIMIT:
            problems.append("%s: %d characters, the limit is %d" % (key, len(value), URL_LIMIT))
    locale = doc.get("locale")
    if "locale" in doc and (not isinstance(locale, str) or not LOCALE_RE.match(locale)):
        problems.append("locale: must look like en-US")
    if "copyright" in doc and doc["copyright"] is not None and not isinstance(doc["copyright"], str):
        problems.append("copyright: must be a string")
    for key in ("primaryCategory", "secondaryCategory"):
        value = doc.get(key)
        if key in doc and value not in (None, "") and (
                not isinstance(value, str) or not CATEGORY_RE.match(value)):
            problems.append("%s: must be an App Store category id such as DEVELOPER_TOOLS" % key)
    rights = doc.get("contentRightsDeclaration")
    if "contentRightsDeclaration" in doc and rights not in (None, "") and rights not in CONTENT_RIGHTS:
        problems.append("contentRightsDeclaration: must be one of %s" % ", ".join(CONTENT_RIGHTS))
    age = doc.get("ageRating")
    if "ageRating" in doc:
        if not isinstance(age, dict):
            problems.append("ageRating: must be an object")
        else:
            for name, value in age.items():
                if not ATTR_NAME_RE.match(str(name)):
                    problems.append("ageRating: an attribute name is not valid")
                elif not (value is None or isinstance(value, (bool, str))):
                    problems.append("ageRating.%s: must be a string, a boolean or null" % name)
    if "reviewDemoRequired" in doc and not isinstance(doc["reviewDemoRequired"], bool):
        problems.append("reviewDemoRequired: must be true or false")
    return problems


def load_listing(path):
    """Return (listing, problems). listing is None when the file is absent or unreadable."""
    if not path or not os.path.isfile(path):
        return None, []
    try:
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
    except (OSError, ValueError) as exc:
        return None, ["the listing file is not valid JSON (%s)" % type(exc).__name__]
    return doc, validate_listing(doc)


# --------------------------------------------------------- API data layer ---

EDITABLE_STATES = (
    "PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED",
    "INVALID_BINARY",
)
IPHONE_TYPES = ("APP_IPHONE_69", "APP_IPHONE_67", "APP_IPHONE_65")
IPAD_TYPES = ("APP_IPAD_PRO_3GEN_129", "APP_IPAD_PRO_129")
SCREENSHOT_MIN, SCREENSHOT_MAX = 1, 10
# Age rating attributes that are legitimately empty on a finished declaration.
AGE_OPTIONAL = frozenset((
    "kidsAgeBand", "ageRatingOverride", "ageRatingOverrideV2", "koreaAgeRatingOverride",
    "gracRatingClassificationNumber", "developerAgeRatingInfoUrl", "seventeenPlus",
    "socialMedia", "socialMediaAgeRestricted",
))


class AuthError(Exception):
    """The API rejected the credentials."""


def attrs(resource):
    return (resource or {}).get("attributes") or {}


def rel_id(resource, name):
    data = (((resource or {}).get("relationships") or {}).get(name) or {}).get("data")
    return data.get("id") if isinstance(data, dict) else None


def version_state(version):
    a = attrs(version)
    return a.get("appVersionState") or a.get("appStoreState") or ""


def info_state(info):
    a = attrs(info)
    return a.get("state") or a.get("appStoreState") or ""


def try_get(api, path, params=None):
    """GET one resource. Returns its data, or None when Apple answers 404."""
    try:
        return api.get(path, params).get("data")
    except AscError as err:
        if err.status == 404:
            return None
        raise


def find_app(api, bundle_id):
    data, _ = api.get_all("/v1/apps", {"filter[bundleId]": bundle_id, "limit": "5"})
    return data[0] if data else None


def list_versions(api, app_id):
    data, _ = api.get_all("/v1/apps/%s/appStoreVersions" % app_id,
                          {"filter[platform]": "IOS", "limit": "50"})
    return data


def pick_editable(versions):
    editable = [v for v in versions if version_state(v) in EDITABLE_STATES]
    for v in editable:
        if version_state(v) == "PREPARE_FOR_SUBMISSION":
            return v
    return editable[0] if editable else None


def attached_build(api, version_id):
    """Return (build, marketing version string) for the build on a version."""
    doc = api.get("/v1/appStoreVersions/%s/build" % version_id, {"include": "preReleaseVersion"})
    build = doc.get("data")
    if not build:
        return None, None
    pre = None
    for item in doc.get("included") or []:
        if item.get("type") == "preReleaseVersions":
            pre = attrs(item).get("version")
    return build, pre


def build_number_key(build):
    try:
        return int(attrs(build).get("version") or 0)
    except ValueError:
        return 0


def list_builds(api, app_id, version_string):
    data, _ = api.get_all("/v1/builds", {
        "filter[app]": app_id,
        "filter[preReleaseVersion.version]": version_string,
        "sort": "-uploadedDate",
        "limit": "200",
    })
    return data


def newest_valid_build(builds):
    valid = [b for b in builds
             if attrs(b).get("processingState") == "VALID" and not attrs(b).get("expired")]
    valid.sort(key=lambda b: (attrs(b).get("uploadedDate") or "", build_number_key(b)), reverse=True)
    return valid[0] if valid else None


def pick_app_info(api, app_id):
    data, _ = api.get_all("/v1/apps/%s/appInfos" % app_id,
                          {"include": "primaryCategory,secondaryCategory", "limit": "10"})
    for info in data:
        if info_state(info) in EDITABLE_STATES:
            return info
    return data[0] if data else None


def version_localisations(api, version_id):
    data, _ = api.get_all("/v1/appStoreVersions/%s/appStoreVersionLocalizations" % version_id,
                          {"limit": "200"})
    return data


def info_localisations(api, info_id):
    data, _ = api.get_all("/v1/appInfos/%s/appInfoLocalizations" % info_id, {"limit": "200"})
    return data


def age_declaration(api, info_id):
    return try_get(api, "/v1/appInfos/%s/ageRatingDeclaration" % info_id)


def review_detail(api, version_id):
    return try_get(api, "/v1/appStoreVersions/%s/appStoreReviewDetail" % version_id)


def screenshot_sets(api, loc_id):
    data, _ = api.get_all("/v1/appStoreVersionLocalizations/%s/appScreenshotSets" % loc_id,
                          {"limit": "50"})
    return data


def screenshots_in_set(api, set_id):
    data, _ = api.get_all("/v1/appScreenshotSets/%s/appScreenshots" % set_id, {"limit": "50"})
    return data


def delivery_state(shot):
    state = attrs(shot).get("assetDeliveryState")
    return state.get("state") if isinstance(state, dict) else None


def price_schedule(api, app_id):
    return try_get(api, "/v1/apps/%s/appPriceSchedule" % app_id)


def manual_prices(api, schedule_id):
    return api.get_all("/v1/appPriceSchedules/%s/manualPrices" % schedule_id,
                       {"include": "appPricePoint", "limit": "200"})


def app_availability(api, app_id):
    return try_get(api, "/v1/apps/%s/appAvailabilityV2" % app_id)


def available_territories(api, availability_id):
    data, _ = api.get_all("/v2/appAvailabilities/%s/territoryAvailabilities" % availability_id,
                          {"limit": "200"})
    return sum(1 for x in data if attrs(x).get("available"))


def is_zero(value):
    try:
        return float(value) == 0.0
    except (TypeError, ValueError):
        return False


# ----------------------------------------------------------------- check ----

class Checker:
    """Read-only report. Each read is guarded: a failed read prints INFO and the run continues."""

    def __init__(self, api, out, bundle_id, listing):
        self.api = api
        self.out = out
        self.bundle_id = bundle_id
        self.listing = listing
        self.missing = 0
        self.read_ok = True

    # -- reporting helpers
    def ok(self, item, text=""):
        self.out.line("PASS", item, text)

    def miss(self, item, text):
        self.missing += 1
        self.out.line("MISSING", item, text)

    def info(self, item, text):
        self.out.line("INFO", item, text)

    def text_field(self, item, value, limit, required, hint):
        n = len(value) if isinstance(value, str) else 0
        if n == 0:
            if required:
                self.miss(item, hint)
            else:
                self.info(item, "not set (optional)")
        elif n > limit:
            self.miss(item, "%d characters, the limit is %d" % (n, limit))
        else:
            self.ok(item, "%d/%d characters" % (n, limit))

    def guarded(self, item, fn):
        """Run one read. Failure prints INFO and sets read_ok False. 401 stops the run."""
        self.read_ok = True
        try:
            return fn()
        except AscError as err:
            if err.status == 401:
                raise AuthError("the API rejected the credentials (HTTP 401)") from None
            self.read_ok = False
            self.info(item, "could not be read: %s" % err.describe())
            return None

    # -- the run
    def run(self):
        try:
            app = find_app(self.api, self.bundle_id)
        except AscError as err:
            if err.status in (401, 403):
                raise AuthError("the API rejected the credentials or the key role (HTTP %d)" % err.status) from None
            raise
        if app is None:
            self.miss("app record", "no app has this bundle id: create it in App Store Connect, Apps, New App")
            self.manual_lines()
            return self.finish()
        self.ok("app record", "found by bundle id")
        app_id = app["id"]
        mask_for_ci(app_id, self.out)
        rights = attrs(app).get("contentRightsDeclaration")
        if rights:
            self.ok("content rights declaration", rights)
        else:
            self.miss("content rights declaration", "not set: run apply, or answer Content Rights in App Information")
        versions = self.guarded("app store versions", lambda: list_versions(self.api, app_id))
        if versions is not None:
            version = pick_editable(versions)
            if version is None:
                states = sorted({version_state(v) or "UNKNOWN" for v in versions})
                self.miss("editable version", "no version can be edited (states: %s): create a new version in App Store Connect"
                          % (", ".join(states) or "none"))
            else:
                self.ok("editable version", "%s, state %s" % (attrs(version).get("versionString"), version_state(version)))
                self.check_version(app_id, version)
        self.check_app_info(app_id)
        self.check_price(app_id)
        self.check_availability(app_id)
        self.manual_lines()
        return self.finish()

    def check_version(self, app_id, version):
        vid = version["id"]
        vstring = attrs(version).get("versionString") or ""
        if attrs(version).get("copyright"):
            self.ok("copyright", "set")
        else:
            self.miss("copyright", "not set: run apply, or enter it on the version page")
        self.check_build(app_id, vid, vstring)
        locs = self.guarded("version localisations", lambda: version_localisations(self.api, vid))
        if locs is not None:
            self.check_version_localisations(locs)
            self.check_screenshots(locs)
        self.check_review(vid)

    def check_build(self, app_id, vid, vstring):
        attached = self.guarded("build attached", lambda: attached_build(self.api, vid))
        attached_ok = self.read_ok
        builds = self.guarded("builds", lambda: list_builds(self.api, app_id, vstring))
        newest = newest_valid_build(builds) if builds is not None else None
        if attached_ok:
            build, pre = attached
            if build is None:
                self.miss("build attached", "no build is attached: run apply, or choose one on the version page")
            else:
                a = attrs(build)
                state = a.get("processingState") or "UNKNOWN"
                number = a.get("version") or "?"
                if pre is not None and pre != vstring:
                    self.miss("build attached", "the attached build is for version %s but the editable version is %s: run apply" % (pre, vstring))
                elif state != "VALID":
                    self.miss("build attached", "build %s is attached but its processing state is %s" % (number, state))
                else:
                    self.ok("build attached", "build %s, version %s, processing %s" % (number, pre or vstring, state))
                if a.get("usesNonExemptEncryption") is None:
                    self.info("build export compliance", "build %s has no export compliance answer yet" % number)
                if newest is not None and newest["id"] != build["id"]:
                    self.info("newest build", "build %s is newer and valid, the attached build is %s"
                              % (attrs(newest).get("version"), number))
        if builds is not None:
            if newest is not None:
                self.ok("newest processed build", "build %s matches version %s" % (attrs(newest).get("version"), vstring))
            else:
                pending = sum(1 for b in builds if attrs(b).get("processingState") == "PROCESSING")
                self.miss("newest processed build",
                          "no valid build for version %s (%d processing, %d other): upload one with the release workflow and wait for processing"
                          % (vstring, pending, len(builds) - pending))

    def wanted_locales(self, locs):
        by_locale = {attrs(l).get("locale"): l for l in locs}
        if self.listing and self.listing.get("locale"):
            return [self.listing["locale"]], by_locale
        return sorted(k for k in by_locale if k), by_locale

    def check_version_localisations(self, locs):
        wanted, by_locale = self.wanted_locales(locs)
        if not wanted:
            self.miss("version localisation", "none exists: run apply")
            return
        for locale in wanted:
            loc = by_locale.get(locale)
            prefix = "version localisation %s " % locale
            if loc is None:
                self.miss(prefix.strip(), "does not exist: run apply")
                continue
            a = attrs(loc)
            self.text_field(prefix + "description", a.get("description"), LIMITS["description"], True, "empty: run apply")
            self.text_field(prefix + "keywords", a.get("keywords"), LIMITS["keywords"], True, "empty: run apply")
            self.text_field(prefix + "promotional text", a.get("promotionalText"), LIMITS["promotionalText"], False, "")
            self.text_field(prefix + "what's new", a.get("whatsNew"), LIMITS["whatsNew"], False, "")
            for field, label, required in (("supportUrl", "support URL", True), ("marketingUrl", "marketing URL", False)):
                if a.get(field):
                    self.ok(prefix + label, "present")
                elif required:
                    self.miss(prefix + label, "empty: run apply")
                else:
                    self.info(prefix + label, "not set (optional)")

    def check_screenshots(self, locs):
        wanted, by_locale = self.wanted_locales(locs)
        if not wanted:
            self.miss("screenshots", "no localisation to hold them: run apply first")
            return
        for locale in wanted:
            loc = by_locale.get(locale)
            if loc is None:
                self.miss("screenshots %s" % locale, "no localisation to hold them: run apply first")
                continue
            sets = self.guarded("screenshot sets %s" % locale, lambda: screenshot_sets(self.api, loc["id"]))
            if sets is None:
                continue
            counts, pending = {}, {}
            for s in sets:
                stype = attrs(s).get("screenshotDisplayType") or "UNKNOWN"
                shots = self.guarded("screenshots %s" % stype, lambda s=s: screenshots_in_set(self.api, s["id"]))
                if shots is None:
                    continue
                counts[stype] = len(shots)
                pending[stype] = sum(1 for x in shots if delivery_state(x) not in (None, "COMPLETE"))
                self.info("screenshots %s %s" % (locale, stype), "%d uploaded" % len(shots))
            for label, types in (("iPhone 6.9 inch", IPHONE_TYPES), ("iPad 13 inch", IPAD_TYPES)):
                item = "screenshots %s %s" % (locale, label)
                present = [(tp, counts[tp]) for tp in types if counts.get(tp)]
                if not present:
                    self.miss(item, "none uploaded (expected in %s): run apply with --screenshots-dir" % types[0])
                    continue
                stype, n = present[0]
                if n > SCREENSHOT_MAX:
                    self.miss(item, "%d screenshots in %s, the maximum is %d" % (n, stype, SCREENSHOT_MAX))
                elif pending.get(stype):
                    self.miss(item, "%d of %d screenshots in %s are not COMPLETE yet" % (pending[stype], n, stype))
                else:
                    self.ok(item, "%d in %s (allowed %d to %d)" % (n, stype, SCREENSHOT_MIN, SCREENSHOT_MAX))

    def check_review(self, vid):
        detail = self.guarded("app review details", lambda: review_detail(self.api, vid))
        if detail is None:
            if self.read_ok:
                self.miss("app review details", "not created: run apply")
            return
        a = attrs(detail)
        if a.get("notes"):
            self.ok("app review notes", "%d characters" % len(a["notes"]))
        else:
            self.miss("app review notes", "empty: run apply")
        for field, label, secret in (
                ("contactFirstName", "first name", "REVIEW_CONTACT_FIRST_NAME"),
                ("contactLastName", "last name", "REVIEW_CONTACT_LAST_NAME"),
                ("contactPhone", "phone", "REVIEW_CONTACT_PHONE"),
                ("contactEmail", "email", "REVIEW_CONTACT_EMAIL")):
            if a.get(field):
                self.ok("app review contact %s" % label, "present")
            else:
                self.miss("app review contact %s" % label,
                          "empty: add the %s secret and run apply, or enter it in App Store Connect" % secret)
        required = a.get("demoAccountRequired")
        if required is None:
            self.miss("app review demo account flag", "not set: run apply")
        elif required:
            if a.get("demoAccountName") and a.get("demoAccountPassword"):
                self.ok("app review demo account", "required and present")
            else:
                self.miss("app review demo account", "required but the name or password is empty: enter them in App Store Connect")
        else:
            self.ok("app review demo account flag", "not required")

    def check_app_info(self, app_id):
        info = self.guarded("app info", lambda: pick_app_info(self.api, app_id))
        if info is None:
            if self.read_ok:
                self.miss("app info", "no app info record was found")
            return
        iid = info["id"]
        primary, secondary = rel_id(info, "primaryCategory"), rel_id(info, "secondaryCategory")
        if primary:
            self.ok("primary category", primary)
        else:
            self.miss("primary category", "not set: run apply, or choose it in App Information")
        if secondary:
            self.ok("secondary category", secondary)
        else:
            self.info("secondary category", "not set (optional)")
        locs = self.guarded("app info localisations", lambda: info_localisations(self.api, iid))
        if locs is not None:
            wanted, by_locale = self.wanted_locales(locs)
            if not wanted:
                self.miss("app info localisation", "none exists: run apply")
            for locale in wanted:
                loc = by_locale.get(locale)
                prefix = "app info localisation %s " % locale
                if loc is None:
                    self.miss(prefix.strip(), "does not exist: run apply")
                    continue
                a = attrs(loc)
                self.text_field(prefix + "name", a.get("name"), LIMITS["name"], True, "empty: run apply")
                self.text_field(prefix + "subtitle", a.get("subtitle"), LIMITS["subtitle"], False, "")
                if a.get("privacyPolicyUrl"):
                    self.ok(prefix + "privacy policy URL", "present")
                else:
                    self.miss(prefix + "privacy policy URL", "empty: run apply")
        decl = self.guarded("age rating", lambda: age_declaration(self.api, iid))
        if self.read_ok:
            if decl is None:
                self.miss("age rating", "no declaration found: answer Age Rating in App Store Connect")
            else:
                a = attrs(decl)
                listed = (self.listing or {}).get("ageRating")
                required = set(listed) if isinstance(listed, dict) and listed else set(a) - AGE_OPTIONAL
                empty = sorted(k for k in required if a.get(k) is None)
                if empty:
                    self.miss("age rating", "%d answer(s) not set (%s): run apply, or answer them in Age Rating"
                              % (len(empty), ", ".join(empty)))
                else:
                    self.ok("age rating", "%d answers set" % len(required))

    def check_price(self, app_id):
        schedule = self.guarded("price schedule", lambda: price_schedule(self.api, app_id))
        if schedule is None:
            if self.read_ok:
                self.miss("price schedule", "not set: run apply to set Free, or choose a price")
            return
        got = self.guarded("price schedule prices", lambda: manual_prices(self.api, schedule["id"]))
        if got is None:
            return
        data, included = got
        if not data:
            self.miss("price schedule", "no price is set: run apply to set Free, or choose a price")
            return
        amounts = [attrs(i).get("customerPrice") for i in included
                   if str(i.get("type", "")).startswith("appPricePoint")]
        if amounts and all(is_zero(x) for x in amounts):
            self.ok("price schedule", "set, Free")
        else:
            self.info("price schedule", "set, not Free")

    def check_availability(self, app_id):
        avail = self.guarded("availability", lambda: app_availability(self.api, app_id))
        if avail is None:
            if self.read_ok:
                self.miss("availability", "not set: choose territories in App Store Connect, Pricing and Availability")
            return
        count = self.guarded("availability territories", lambda: available_territories(self.api, avail["id"]))
        if count is None:
            return
        if count:
            self.ok("availability", "%d territories" % count)
        else:
            self.miss("availability", "no territory is available: choose territories in Pricing and Availability")

    def manual_lines(self):
        self.out.line("MANUAL", "App Privacy questionnaire",
                      "answer Data Not Collected in App Store Connect, App Privacy")
        self.out.line("MANUAL", "Export compliance",
                      "is set per build; confirm the build shows no Missing Compliance")
        self.out.line("MANUAL", "Press Submit for Review")

    def finish(self):
        if self.missing:
            self.out.raw("RESULT: %d item(s) missing. Fix them, then run check again." % self.missing)
        else:
            self.out.raw("RESULT: nothing missing that the API can see. Do the manual steps.")
        return 0


def run_check(api, out, bundle_id, listing):
    return Checker(api, out, bundle_id, listing).run()


# ----------------------------------------------------------------- apply ----

STEP_NAMES = ("localisation", "appinfo", "copyright", "agerating", "contentrights",
              "build", "review", "screenshots", "price")
RELEASED_STATES = (
    "READY_FOR_SALE", "REPLACED_WITH_NEW_VERSION", "REMOVED_FROM_SALE", "DEVELOPER_REMOVED_FROM_SALE",
    "PENDING_DEVELOPER_RELEASE", "PENDING_APPLE_RELEASE", "PROCESSING_FOR_APP_STORE",
    "READY_FOR_DISTRIBUTION",
)
FREE_PRICE_REF = "${local-price-1}"


def contact_from_env(env=None):
    """Return the four review contact values, or None when any one is absent."""
    env = os.environ if env is None else env
    values = [env.get(name, "").strip() for name in REVIEW_CONTACT_ENV]
    if not all(values):
        return None
    return {
        "contactFirstName": values[0],
        "contactLastName": values[1],
        "contactPhone": values[2],
        "contactEmail": values[3],
    }


def changed(current, desired):
    """Return the part of desired that differs from current."""
    return {k: v for k, v in desired.items() if current.get(k) != v}


def wanted(listing, keys):
    """Values from the listing for keys that hold a non-empty value."""
    out = {}
    for key in keys:
        value = listing.get(key)
        if isinstance(value, str) and value.strip() == "":
            continue
        if value is None:
            continue
        out[key] = value
    return out


class Applier:
    """Idempotent writes. Never deletes, never submits and never creates a review submission."""

    def __init__(self, api, out, bundle_id, listing, steps=STEP_NAMES, build_number=None,
                 screenshots_dir=None, replace_screenshots=False, base_territory="USA",
                 contact=None, sleep=time.sleep, clock=time.time):
        self.api = api
        self.out = out
        self.bundle_id = bundle_id
        self.listing = listing
        self.steps = tuple(steps)
        self.build_number = build_number
        self.screenshots_dir = screenshots_dir
        self.replace_screenshots = replace_screenshots
        self.base_territory = base_territory
        self.contact = contact
        self.sleep = sleep
        self.clock = clock
        self.failed = 0
        self.locale = listing["locale"]
        self.app_id = None
        self.version = None
        self.versions = []
        self.info = None

    # -- reporting
    def set(self, step, text):
        self.out.line("SET", step, text)

    def skip(self, step, text):
        self.out.line("SKIP", step, text)

    def fail(self, step, text):
        self.failed += 1
        self.out.line("FAIL", step, text)

    def guarded(self, step, fn):
        try:
            fn()
        except AscError as err:
            if err.status == 401:
                raise AuthError("the API rejected the credentials (HTTP 401)") from None
            self.fail(step, err.describe())
        except ConfigError as exc:
            self.fail(step, str(exc))

    # -- the run
    def run(self):
        try:
            app = find_app(self.api, self.bundle_id)
        except AscError as err:
            if err.status in (401, 403):
                raise AuthError("the API rejected the credentials or the key role (HTTP %d)" % err.status) from None
            raise
        if app is None:
            self.fail("app record", "no app has this bundle id: create it in App Store Connect, Apps, New App")
            return self.finish()
        self.app_id = app["id"]
        mask_for_ci(self.app_id, self.out)
        self.app = app
        try:
            self.versions = list_versions(self.api, self.app_id)
            self.version = pick_editable(self.versions)
            self.info = pick_app_info(self.api, self.app_id)
        except AscError as err:
            if err.status == 401:
                raise AuthError("the API rejected the credentials (HTTP 401)") from None
            self.fail("lookup", err.describe())
            return self.finish()
        if self.version is None:
            self.fail("editable version", "no version can be edited: create a new version in App Store Connect")
            return self.finish()
        table = {
            "localisation": self.step_localisation,
            "appinfo": self.step_appinfo,
            "copyright": self.step_copyright,
            "agerating": self.step_agerating,
            "contentrights": self.step_contentrights,
            "build": self.step_build,
            "review": self.step_review,
            "screenshots": self.step_screenshots,
            "price": self.step_price,
        }
        for name in STEP_NAMES:
            if name not in self.steps:
                self.skip(name, "not selected with --steps")
                continue
            self.guarded(name, table[name])
        return self.finish()

    def finish(self):
        if self.failed:
            self.out.raw("RESULT: %d step(s) failed. Nothing was submitted." % self.failed)
            return 1
        self.out.raw("RESULT: apply finished. Run check, then do the manual steps. Nothing was submitted.")
        return 0

    # -- helpers
    def upsert(self, rtype, parent_rel, parent_type, parent_id, current_list, desired, label):
        """Create or update a localisation-style resource for the listing locale."""
        item = "%s %s" % (label, self.locale)
        current = next((r for r in current_list if attrs(r).get("locale") == self.locale), None)
        if not desired:
            self.skip(item, "the listing has no values")
            return
        if current is None:
            body = {"data": {"type": rtype, "attributes": dict(desired, locale=self.locale),
                             "relationships": {parent_rel: {"data": {"type": parent_type, "id": parent_id}}}}}
            self.api.post("/v1/%s" % rtype, body)
            self.set(item, "created: %s" % ", ".join(sorted(desired)))
            return
        diff = changed(attrs(current), desired)
        if not diff:
            self.skip(item, "already up to date")
            return
        self.api.patch("/v1/%s/%s" % (rtype, current["id"]),
                       {"data": {"type": rtype, "id": current["id"], "attributes": diff}})
        self.set(item, "updated: %s" % ", ".join(sorted(diff)))

    def first_version(self):
        return not any(version_state(v) in RELEASED_STATES for v in self.versions
                       if v["id"] != self.version["id"])

    # -- steps
    def step_localisation(self):
        fields = ["description", "keywords", "promotionalText", "supportUrl", "marketingUrl", "whatsNew"]
        if self.first_version():
            if wanted(self.listing, ["whatsNew"]):
                self.skip("localisation", "what's new is not set because this is the first version")
            fields.remove("whatsNew")
        desired = wanted(self.listing, fields)
        current = version_localisations(self.api, self.version["id"])
        self.upsert("appStoreVersionLocalizations", "appStoreVersion", "appStoreVersions",
                    self.version["id"], current, desired, "version localisation")

    def step_appinfo(self):
        if self.info is None:
            self.fail("appinfo", "no app info record was found")
            return
        iid = self.info["id"]
        desired = wanted(self.listing, ["name", "subtitle", "privacyPolicyUrl"])
        current = info_localisations(self.api, iid)
        self.upsert("appInfoLocalizations", "appInfo", "appInfos", iid, current, desired,
                    "app info localisation")
        rels = {}
        done = []
        for key in ("primaryCategory", "secondaryCategory"):
            value = self.listing.get(key)
            if not value:
                continue
            if rel_id(self.info, key) != value:
                rels[key] = {"data": {"type": "appCategories", "id": value}}
                done.append(key)
        if rels:
            self.api.patch("/v1/appInfos/%s" % iid,
                           {"data": {"type": "appInfos", "id": iid, "relationships": rels}})
            self.set("categories", "updated: %s" % ", ".join(done))
        else:
            self.skip("categories", "already up to date or not in the listing")

    def step_copyright(self):
        value = self.listing.get("copyright")
        if not value:
            self.skip("copyright", "the listing has no value")
            return
        if attrs(self.version).get("copyright") == value:
            self.skip("copyright", "already up to date")
            return
        self.api.patch("/v1/appStoreVersions/%s" % self.version["id"], {
            "data": {"type": "appStoreVersions", "id": self.version["id"], "attributes": {"copyright": value}}})
        self.set("copyright", "updated")

    def step_agerating(self):
        answers = {k: v for k, v in (self.listing.get("ageRating") or {}).items() if v is not None}
        if not answers:
            self.skip("age rating", "the listing has no answers")
            return
        if self.info is None:
            self.fail("age rating", "no app info record was found")
            return
        decl = age_declaration(self.api, self.info["id"])
        if decl is None:
            self.fail("age rating", "no age rating declaration exists to update")
            return
        diff = changed(attrs(decl), answers)
        if not diff:
            self.skip("age rating", "already up to date")
            return
        self.api.patch("/v1/ageRatingDeclarations/%s" % decl["id"], {
            "data": {"type": "ageRatingDeclarations", "id": decl["id"], "attributes": diff}})
        self.set("age rating", "updated %d answer(s): %s" % (len(diff), ", ".join(sorted(diff))))

    def step_contentrights(self):
        value = self.listing.get("contentRightsDeclaration")
        if not value:
            self.skip("content rights", "the listing has no value")
            return
        if attrs(self.app).get("contentRightsDeclaration") == value:
            self.skip("content rights", "already up to date")
            return
        self.api.patch("/v1/apps/%s" % self.app_id, {
            "data": {"type": "apps", "id": self.app_id, "attributes": {"contentRightsDeclaration": value}}})
        self.set("content rights", "updated")

    def step_build(self):
        vstring = attrs(self.version).get("versionString") or ""
        builds = list_builds(self.api, self.app_id, vstring)
        valid = [b for b in builds if attrs(b).get("processingState") == "VALID" and not attrs(b).get("expired")]
        if self.build_number is not None:
            chosen = next((b for b in valid if attrs(b).get("version") == str(self.build_number)), None)
            if chosen is None:
                self.fail("build", "no valid build number %s exists for version %s" % (self.build_number, vstring))
                return
        else:
            chosen = newest_valid_build(builds)
            if chosen is None:
                self.skip("build", "no valid build exists for version %s: upload one and wait for processing" % vstring)
                return
        current, _pre = attached_build(self.api, self.version["id"])
        if current is not None and current["id"] == chosen["id"]:
            self.skip("build", "build %s is already attached" % attrs(chosen).get("version"))
            return
        self.api.patch("/v1/appStoreVersions/%s/relationships/build" % self.version["id"],
                       {"data": {"type": "builds", "id": chosen["id"]}})
        self.set("build", "attached build %s to version %s" % (attrs(chosen).get("version"), vstring))

    def step_review(self):
        desired = {}
        notes = self.listing.get("reviewNotes")
        if isinstance(notes, str) and notes.strip():
            desired["notes"] = notes
        if isinstance(self.listing.get("reviewDemoRequired"), bool):
            desired["demoAccountRequired"] = self.listing["reviewDemoRequired"]
        if self.contact:
            desired.update(self.contact)
        else:
            self.skip("review contact", "the REVIEW_CONTACT_* secrets are not all set: enter the contact in App Store Connect")
        if not desired:
            self.skip("app review details", "the listing has no values")
            return
        vid = self.version["id"]
        detail = review_detail(self.api, vid)
        fields = ", ".join(sorted(desired))
        if detail is None:
            self.api.post("/v1/appStoreReviewDetails", {"data": {
                "type": "appStoreReviewDetails", "attributes": desired,
                "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": vid}}}}})
            self.set("app review details", "created: %s" % fields)
            return
        diff = changed(attrs(detail), desired)
        if not diff:
            self.skip("app review details", "already up to date")
            return
        self.api.patch("/v1/appStoreReviewDetails/%s" % detail["id"], {
            "data": {"type": "appStoreReviewDetails", "id": detail["id"], "attributes": diff}})
        self.set("app review details", "updated: %s" % ", ".join(sorted(diff)))

    def step_screenshots(self):
        self.skip("screenshots", "no --screenshots-dir was given") if not self.screenshots_dir else None

    def step_price(self):
        if price_schedule(self.api, self.app_id) is not None:
            self.skip("price schedule", "a price schedule already exists")
            return
        points, _ = self.api.get_all("/v1/apps/%s/appPricePoints" % self.app_id,
                                     {"filter[territory]": self.base_territory, "limit": "200"})
        free = next((p for p in points if is_zero(attrs(p).get("customerPrice"))), None)
        if free is None:
            self.fail("price schedule", "no Free price point was found for the base territory")
            return
        self.api.post("/v1/appPriceSchedules", {
            "data": {"type": "appPriceSchedules", "relationships": {
                "app": {"data": {"type": "apps", "id": self.app_id}},
                "baseTerritory": {"data": {"type": "territories", "id": self.base_territory}},
                "manualPrices": {"data": [{"type": "appPrices", "id": FREE_PRICE_REF}]}}},
            "included": [{"type": "appPrices", "id": FREE_PRICE_REF, "attributes": {"startDate": None},
                          "relationships": {"appPricePoint": {"data": {"type": "appPricePoints", "id": free["id"]}}}}]})
        self.set("price schedule", "Free set for the base territory")


def run_apply(api, out, bundle_id, listing, **kw):
    return Applier(api, out, bundle_id, listing, **kw).run()


# ---------------------------------------------------------------- CLI -------

def read_env(out):
    key_id = os.environ.get("ASC_API_KEY_ID", "").strip()
    issuer = os.environ.get("ASC_API_ISSUER_ID", "").strip()
    bundle = os.environ.get("APP_BUNDLE_ID", "").strip()
    key_path = os.environ.get("ASC_API_KEY_P8_PATH", "").strip()
    for value in (key_id, issuer, bundle):
        out.add_secret(value)
    for name in REVIEW_CONTACT_ENV:
        out.add_secret(os.environ.get(name, ""))
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
    chk.add_argument("--listing", default="AppStore/listing.json",
                     help="path to listing.json (optional for check, ignored when the file is absent)")
    app = sub.add_parser("apply", help="write listing data, build and screenshots")
    app.add_argument("--listing", default="AppStore/listing.json")
    app.add_argument("--steps", default="all",
                     help="comma separated subset of: " + ", ".join(STEP_NAMES) + " (default all)")
    app.add_argument("--build-number", default=None,
                     help="attach this build number instead of the newest valid build")
    app.add_argument("--screenshots-dir", default=None,
                     help="directory with one sub folder per display type, for example APP_IPHONE_67")
    app.add_argument("--replace-screenshots", action="store_true",
                     help="replace a screenshot set that already holds screenshots")
    app.add_argument("--base-territory", default="USA", help="territory for the Free price (default USA)")
    return parser


def parse_steps(text):
    if text.strip() in ("", "all"):
        return STEP_NAMES
    names = tuple(x.strip() for x in text.split(",") if x.strip())
    unknown = [n for n in names if n not in STEP_NAMES]
    if unknown:
        raise ConfigError("unknown step name(s): %s" % ", ".join(unknown))
    return names


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
    listing, problems = load_listing(args.listing)
    if problems:
        for problem in problems:
            out.raw("ERROR listing: %s" % problem)
        if args.command == "apply":
            return 1
        listing = None
        out.raw("INFO listing: ignored for check because it is not valid")
    steps, build_number, contact = STEP_NAMES, None, None
    if args.command == "apply":
        if listing is None:
            out.raw("ERROR listing: the listing file was not found")
            return 1
        try:
            steps = parse_steps(args.steps)
            if args.build_number is not None:
                if not re.match(r"^[0-9]{1,9}$", str(args.build_number)):
                    raise ConfigError("--build-number must be a whole number")
                build_number = str(int(args.build_number))
            if args.screenshots_dir and not os.path.isdir(args.screenshots_dir):
                raise ConfigError("--screenshots-dir is not a directory")
        except ConfigError as exc:
            out.raw("ERROR configuration: %s" % exc)
            return 2
        contact = contact_from_env()
        for value in (contact or {}).values():
            out.add_secret(value)
    try:
        if args.command == "check":
            code = run_check(api, out, bundle, listing)
            out.write_summary("App Store Connect check")
            return code
        code = run_apply(api, out, bundle, listing, steps=steps, build_number=build_number,
                         screenshots_dir=args.screenshots_dir,
                         replace_screenshots=args.replace_screenshots,
                         base_territory=args.base_territory, contact=contact,
                         sleep=sleep, clock=clock)
        out.write_summary("App Store Connect apply")
        return code
    except AuthError as exc:
        out.raw("ERROR credentials: %s" % exc)
        return 2
    except NetworkError as exc:
        out.raw("ERROR network: %s" % exc)
        return 2
    except ConfigError as exc:
        out.raw("ERROR configuration: %s" % exc)
        return 2


if __name__ == "__main__":
    sys.exit(main())
