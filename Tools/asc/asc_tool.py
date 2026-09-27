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


def resolve_locale(app, override, listing):
    """Return (locale, where it came from). The listing text is written to this locale."""
    if override:
        return override, "from --locale"
    primary = attrs(app).get("primaryLocale")
    if primary:
        return primary, "the app's primary locale"
    if listing and listing.get("locale"):
        return listing["locale"], "from the listing, because the app reports no primary locale"
    return None, ""


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
    """Return the build attached to a version, or None. This endpoint takes no include parameter."""
    return try_get(api, "/v1/appStoreVersions/%s/build" % version_id)


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
    path = "/v1/appPriceSchedules/%s/manualPrices" % schedule_id
    try:
        return api.get_all(path, {"include": "appPricePoint", "limit": "200"})
    except AscError as err:
        if err.status != 400:
            raise
        return api.get_all(path, {"limit": "200"})


def current_prices(api, app_id):
    """Return (prices, included) for the manual prices, or None when no price is set.

    Apple answers with a schedule stub that carries the app id even when nothing is set, and
    the manualPrices call on that stub is a 404. Both count as "not set".
    """
    schedule = price_schedule(api, app_id)
    if schedule is None:
        return None
    try:
        data, included = manual_prices(api, schedule["id"])
    except AscError as err:
        if err.status == 404:
            return None
        raise
    return (data, included) if data else None


def list_all_builds(api, app_id):
    """Return [(build, marketing version)] for every build of the app, newest upload first."""
    data, included = api.get_all("/v1/builds", {
        "filter[app]": app_id, "include": "preReleaseVersion", "sort": "-uploadedDate", "limit": "200"})
    versions = {i["id"]: attrs(i).get("version") for i in included if i.get("type") == "preReleaseVersions"}
    return [(b, versions.get(rel_id(b, "preReleaseVersion"))) for b in data]


def newest_valid_pair(pairs):
    """The newest valid, unexpired (build, version) pair."""
    valid = [(b, v) for b, v in pairs
             if attrs(b).get("processingState") == "VALID" and not attrs(b).get("expired")]
    valid.sort(key=lambda bv: (attrs(bv[0]).get("uploadedDate") or "", build_number_key(bv[0])), reverse=True)
    return valid[0] if valid else (None, None)


def list_territory_ids(api):
    data, _ = api.get_all("/v1/territories", {"limit": "200"})
    return [t["id"] for t in data]


def app_availability(api, app_id):
    return try_get(api, "/v1/apps/%s/appAvailabilityV2" % app_id)


def available_territories(api, availability_id):
    data, _ = api.get_all("/v2/appAvailabilities/%s/territoryAvailabilities" % availability_id,
                          {"limit": "200"})
    return sum(1 for x in data if attrs(x).get("available"))


def count_territories(api, availability_id):
    """Available territory count. A 404 on a stub availability counts as none."""
    try:
        return available_territories(api, availability_id)
    except AscError as err:
        if err.status == 404:
            return 0
        raise


def is_zero(value):
    try:
        return float(value) == 0.0
    except (TypeError, ValueError):
        return False


# ----------------------------------------------------------------- check ----

class Checker:
    """Read-only report. Each read is guarded: a failed read prints INFO and the run continues."""

    def __init__(self, api, out, bundle_id, listing, locale=None):
        self.api = api
        self.out = out
        self.bundle_id = bundle_id
        self.listing = listing
        self.locale_override = locale
        self.locale = None
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
        self.locale, where = resolve_locale(app, self.locale_override, self.listing)
        if self.locale:
            self.info("target locale", "%s (%s)" % (self.locale, where))
            source = (self.listing or {}).get("locale")
            if source and source != self.locale:
                self.info("listing text", "written from listing locale %s to %s" % (source, self.locale))
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
            build = attached
            if build is None:
                self.miss("build attached", "no build is attached: run apply, or choose one on the version page")
            else:
                a = attrs(build)
                state = a.get("processingState") or "UNKNOWN"
                number = a.get("version") or "?"
                if builds is not None and build["id"] not in {b["id"] for b in builds}:
                    self.miss("build attached", "the attached build %s is not a build of version %s: run apply" % (number, vstring))
                elif state != "VALID":
                    self.miss("build attached", "build %s is attached but its processing state is %s" % (number, state))
                else:
                    self.ok("build attached", "build %s, version %s, processing %s" % (number, vstring, state))
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
        self.check_version_string(app_id, vstring)

    def check_version_string(self, app_id, vstring):
        pairs = self.guarded("version string", lambda: list_all_builds(self.api, app_id))
        if pairs is None:
            return
        build, version = newest_valid_pair(pairs)
        if build is None or not version:
            return
        number = attrs(build).get("version")
        if version == vstring:
            self.ok("version string", "%s matches the newest valid build (build %s)" % (vstring, number))
        else:
            self.miss("version string",
                      "the editable version is %s but the newest valid build (build %s) is for %s: apply sets the version to %s and attaches that build, or use --set-version keep to stay on %s"
                      % (vstring, number, version, version, vstring))

    def wanted_locales(self, locs):
        by_locale = {attrs(l).get("locale"): l for l in locs}
        if self.locale:
            return [self.locale], by_locale
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
        got = self.guarded("price schedule", lambda: current_prices(self.api, app_id))
        if not self.read_ok:
            return
        if got is None:
            self.miss("price schedule", "not set: run apply to set Free, or choose a price")
            return
        _data, included = got
        amounts = [attrs(i).get("customerPrice") for i in included
                   if str(i.get("type", "")).startswith("appPricePoint")]
        if amounts and all(is_zero(x) for x in amounts):
            self.ok("price schedule", "set, Free")
        elif amounts:
            self.info("price schedule", "set, not Free")
        else:
            self.ok("price schedule", "set")

    def check_availability(self, app_id):
        avail = self.guarded("availability", lambda: app_availability(self.api, app_id))
        if avail is None:
            if self.read_ok:
                self.miss("availability", "not set: run apply, or choose territories in Pricing and Availability")
            return
        count = self.guarded("availability territories", lambda: count_territories(self.api, avail["id"]))
        if count is None:
            return
        if count:
            self.ok("availability", "%d territories" % count)
        else:
            self.miss("availability", "no territory is available: run apply, or choose territories in Pricing and Availability")

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


def run_check(api, out, bundle_id, listing, locale=None):
    return Checker(api, out, bundle_id, listing, locale=locale).run()


# ------------------------------------------------------------ screenshots --

def _both(width, height):
    return {(width, height), (height, width)}


_IPHONE_69 = _both(1260, 2736) | _both(1290, 2796) | _both(1320, 2868)
# Accepted pixel sizes per display type, from Apple's screenshot specifications.
DISPLAY_SIZES = {
    "APP_IPHONE_69": _IPHONE_69,
    "APP_IPHONE_67": _IPHONE_69,
    "APP_IPHONE_65": _both(1242, 2688) | _both(1284, 2778),
    "APP_IPHONE_61": _both(1206, 2622) | _both(1179, 2556),
    "APP_IPHONE_58": _both(1170, 2532) | _both(1125, 2436) | _both(1080, 2340),
    "APP_IPHONE_55": _both(1242, 2208),
    "APP_IPHONE_47": _both(750, 1334),
    "APP_IPAD_PRO_3GEN_129": _both(2048, 2732) | _both(2064, 2752),
    "APP_IPAD_PRO_129": _both(2048, 2732),
    "APP_IPAD_PRO_3GEN_11": _both(1488, 2266) | _both(1668, 2388) | _both(1668, 2420) | _both(1640, 2360),
    "APP_IPAD_105": _both(1668, 2224),
    "APP_IPAD_97": _both(1536, 2048),
}
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
UPLOAD_POLL_SECONDS = 2
UPLOAD_TIMEOUT_SECONDS = 180
MAX_SCREENSHOT_BYTES = 30 * 1024 * 1024


def png_info(data):
    """Return (width, height, has_alpha) for PNG bytes, or None when they are not a PNG."""
    if len(data) < 33 or data[:8] != PNG_SIGNATURE or data[12:16] != b"IHDR":
        return None
    width, height = struct.unpack(">II", data[16:24])
    colour_type = data[25]
    return width, height, colour_type in (4, 6)


def natural_key(name):
    return [int(part) if part.isdigit() else part.lower() for part in re.split(r"(\d+)", name)]


# ----------------------------------------------------------------- apply ----

STEP_NAMES = ("localisation", "appinfo", "copyright", "agerating", "contentrights",
              "version", "build", "review", "screenshots", "price", "availability")
VERSION_RE = re.compile(r"^[0-9]+(\.[0-9]+){0,2}$")
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
                 contact=None, sleep=time.sleep, clock=time.time, locale=None,
                 set_version="auto", build_version=None, territories="all"):
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
        self.locale_override = locale
        self.locale = None
        self.set_version = set_version
        self.build_version = build_version
        self.territories = territories
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
        self.locale, where = resolve_locale(app, self.locale_override, self.listing)
        if self.locale is None:
            self.fail("locale", "the app reports no primary locale: pass --locale")
            return self.finish()
        self.out.line("INFO", "target locale", "%s (%s)" % (self.locale, where))
        source = self.listing.get("locale")
        if source and source != self.locale:
            self.out.line("INFO", "listing text", "written from listing locale %s to %s" % (source, self.locale))
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
            "version": self.step_version,
            "build": self.step_build,
            "review": self.step_review,
            "screenshots": self.step_screenshots,
            "price": self.step_price,
            "availability": self.step_availability,
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

    def step_version(self):
        current = attrs(self.version).get("versionString") or ""
        mode = self.set_version
        if mode == "keep":
            self.skip("version", "kept at %s" % current)
            return
        state = version_state(self.version)
        if state not in EDITABLE_STATES:
            self.fail("version", "the version is in state %s and cannot be changed" % state)
            return
        if mode == "auto":
            pairs = list_all_builds(self.api, self.app_id)
            if self.build_version:
                pairs = [(b, v) for b, v in pairs if v == self.build_version]
            if self.build_number is not None:
                pairs = [(b, v) for b, v in pairs if attrs(b).get("version") == str(self.build_number)]
            build, target = newest_valid_pair(pairs)
            if build is None or not target:
                self.skip("version", "no valid build to take a version from, kept at %s" % current)
                return
            reason = "from build %s" % attrs(build).get("version")
        else:
            target, reason = mode, "from --set-version"
        if target == current:
            self.skip("version", "already %s" % current)
            return
        self.api.patch("/v1/appStoreVersions/%s" % self.version["id"], {
            "data": {"type": "appStoreVersions", "id": self.version["id"], "attributes": {"versionString": target}}})
        self.version.setdefault("attributes", {})["versionString"] = target
        self.set("version", "changed the version from %s to %s (%s)" % (current, target, reason))

    def step_build(self):
        vstring = attrs(self.version).get("versionString") or ""
        if self.build_version and self.build_version != vstring:
            self.fail("build", "--build-version %s does not match the editable version %s: use --set-version" % (self.build_version, vstring))
            return
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
        current = attached_build(self.api, self.version["id"])
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

    # -- screenshots
    def plan_screenshots(self):
        """Read and validate the screenshot tree. Returns [(display type, [(name, bytes)])]."""
        root = self.screenshots_dir
        folders = sorted(d for d in os.listdir(root) if os.path.isdir(os.path.join(root, d)))
        plan = []
        for folder in folders:
            item = "screenshots %s" % folder
            sizes = DISPLAY_SIZES.get(folder)
            if sizes is None:
                self.fail(item, "the folder name is not a known display type")
                continue
            files = sorted((f for f in os.listdir(os.path.join(root, folder)) if f.lower().endswith(".png")),
                           key=natural_key)
            if not files:
                self.skip(item, "the folder holds no PNG files")
                continue
            if len(files) > SCREENSHOT_MAX:
                self.fail(item, "%d files, the maximum is %d" % (len(files), SCREENSHOT_MAX))
                continue
            loaded, problems = [], 0
            for index, name in enumerate(files, 1):
                path = os.path.join(root, folder, name)
                if os.path.getsize(path) > MAX_SCREENSHOT_BYTES:
                    self.fail(item, "file %d is larger than %d MB" % (index, MAX_SCREENSHOT_BYTES // (1024 * 1024)))
                    problems += 1
                    continue
                with open(path, "rb") as fh:
                    data = fh.read()
                info = png_info(data)
                if info is None:
                    self.fail(item, "file %d is not a PNG" % index)
                    problems += 1
                elif (info[0], info[1]) not in sizes:
                    self.fail(item, "file %d is %dx%d pixels, which %s does not accept" % (index, info[0], info[1], folder))
                    problems += 1
                else:
                    if info[2]:
                        self.out.line("INFO", item, "file %d has an alpha channel, Apple can reject that" % index)
                    loaded.append((name, data))
            if problems == 0:
                plan.append((folder, loaded))
        return plan

    def step_screenshots(self):
        if not self.screenshots_dir:
            self.skip("screenshots", "no --screenshots-dir was given")
            return
        plan = self.plan_screenshots()
        if not plan:
            self.skip("screenshots", "no valid display type folder to upload")
            return
        locs = version_localisations(self.api, self.version["id"])
        loc = next((l for l in locs if attrs(l).get("locale") == self.locale), None)
        if loc is None:
            self.fail("screenshots", "the version localisation %s does not exist: run the localisation step first" % self.locale)
            return
        for display_type, files in plan:
            self.guarded("screenshots %s" % display_type,
                         lambda dt=display_type, fl=files: self.upload_set(loc["id"], dt, fl))

    def upload_set(self, loc_id, display_type, files):
        item = "screenshots %s" % display_type
        sets = screenshot_sets(self.api, loc_id)
        current = next((s for s in sets if attrs(s).get("screenshotDisplayType") == display_type), None)
        existing = screenshots_in_set(self.api, current["id"]) if current else []
        if existing and not self.replace_screenshots:
            self.skip(item, "%d screenshot(s) already uploaded, use --replace-screenshots to replace them" % len(existing))
            return
        for shot in existing:
            self.api.delete("/v1/appScreenshots/%s" % shot["id"])
        if existing:
            self.set(item, "removed %d screenshot(s) for replacement" % len(existing))
        if current is None:
            created = self.api.post("/v1/appScreenshotSets", {"data": {
                "type": "appScreenshotSets", "attributes": {"screenshotDisplayType": display_type},
                "relationships": {"appStoreVersionLocalization": {
                    "data": {"type": "appStoreVersionLocalizations", "id": loc_id}}}}})
            set_id = created["data"]["id"]
        else:
            set_id = current["id"]
        ids = []
        for index, (name, data) in enumerate(files, 1):
            ids.append(self.upload_file(index, set_id, name, data))
        if len(ids) > 1:
            self.api.patch("/v1/appScreenshotSets/%s/relationships/appScreenshots" % set_id,
                           {"data": [{"type": "appScreenshots", "id": i} for i in ids]})
        self.set(item, "uploaded %d screenshot(s) in order" % len(ids))

    def upload_file(self, index, set_id, name, data):
        """Apple's three steps: reserve, upload the parts, commit with the checksum. Then poll."""
        reserved = self.api.post("/v1/appScreenshots", {"data": {
            "type": "appScreenshots", "attributes": {"fileName": name, "fileSize": len(data)},
            "relationships": {"appScreenshotSet": {"data": {"type": "appScreenshotSets", "id": set_id}}}}})
        shot = reserved["data"]
        operations = attrs(shot).get("uploadOperations") or []
        if not operations:
            raise ConfigError("file %d: Apple returned no upload operations" % index)
        for op in operations:
            headers = {h.get("name"): h.get("value") for h in (op.get("requestHeaders") or []) if h.get("name")}
            offset, length = int(op.get("offset") or 0), int(op.get("length") or 0)
            self.api.put_part(op.get("method") or "PUT", op.get("url") or "", headers, data[offset:offset + length])
        committed = self.api.patch("/v1/appScreenshots/%s" % shot["id"], {"data": {
            "type": "appScreenshots", "id": shot["id"],
            "attributes": {"uploaded": True, "sourceFileChecksum": hashlib.md5(data).hexdigest()}}})
        state = delivery_state(committed.get("data"))
        deadline = self.clock() + UPLOAD_TIMEOUT_SECONDS
        while state != "COMPLETE":
            if state == "FAILED":
                errors = (attrs(committed.get("data")).get("assetDeliveryState") or {}).get("errors") or []
                codes = ", ".join(str(e.get("code")) for e in errors if isinstance(e, dict)) or "no detail"
                raise ConfigError("file %d: Apple could not process the upload (%s). Run again with --replace-screenshots" % (index, codes))
            if self.clock() > deadline:
                raise ConfigError("file %d: the upload did not reach COMPLETE within %d seconds" % (index, UPLOAD_TIMEOUT_SECONDS))
            self.sleep(UPLOAD_POLL_SECONDS)
            committed = self.api.get("/v1/appScreenshots/%s" % shot["id"])
            state = delivery_state(committed.get("data"))
        return shot["id"]

    def step_price(self):
        if current_prices(self.api, self.app_id) is not None:
            self.skip("price schedule", "a price is already set")
            return
        points, _ = self.api.get_all("/v1/apps/%s/appPricePoints" % self.app_id,
                                     {"filter[territory]": self.base_territory, "limit": "200"})
        free = next((p for p in points if is_zero(attrs(p).get("customerPrice"))), None)
        if free is None:
            self.fail("price schedule", "no Free price point was found for the base territory")
            return
        start = time.strftime("%Y-%m-%d", time.gmtime(self.clock()))
        self.api.post("/v1/appPriceSchedules", {
            "data": {"type": "appPriceSchedules", "relationships": {
                "app": {"data": {"type": "apps", "id": self.app_id}},
                "baseTerritory": {"data": {"type": "territories", "id": self.base_territory}},
                "manualPrices": {"data": [{"type": "appPrices", "id": FREE_PRICE_REF}]}}},
            "included": [{"type": "appPrices", "id": FREE_PRICE_REF, "attributes": {"startDate": start},
                          "relationships": {"appPricePoint": {"data": {"type": "appPricePoints", "id": free["id"]}}}}]})
        self.set("price schedule", "Free set for the base territory")

    def step_availability(self):
        existing = app_availability(self.api, self.app_id)
        if existing is not None:
            count = count_territories(self.api, existing["id"])
            if count:
                self.skip("availability", "already set for %d territories" % count)
                return
        known = list_territory_ids(self.api)
        if self.territories == "all":
            chosen, new_ones = known, True
        else:
            chosen, new_ones = [t for t in self.territories.split(",") if t], False
            unknown = [t for t in chosen if t not in known]
            if unknown:
                self.fail("availability", "%d unknown territory code(s) in --territories" % len(unknown))
                return
        if not chosen:
            self.fail("availability", "Apple returned no territories")
            return
        refs = ["${local-%s}" % t.lower() for t in chosen]
        self.api.post("/v2/appAvailabilities", {
            "data": {"type": "appAvailabilities", "attributes": {"availableInNewTerritories": new_ones},
                     "relationships": {
                         "app": {"data": {"type": "apps", "id": self.app_id}},
                         "territoryAvailabilities": {"data": [{"type": "territoryAvailabilities", "id": r} for r in refs]}}},
            "included": [{"type": "territoryAvailabilities", "id": r, "attributes": {"available": True},
                          "relationships": {"territory": {"data": {"type": "territories", "id": t}}}}
                         for r, t in zip(refs, chosen)]})
        self.set("availability", "set for %d territories%s" % (len(chosen), ", new territories included" if new_ones else ""))


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
    chk.add_argument("--locale", default=None,
                     help="target locale, default is the app's primary locale")
    app = sub.add_parser("apply", help="write listing data, build and screenshots")
    app.add_argument("--listing", default="AppStore/listing.json")
    app.add_argument("--locale", default=None,
                     help="target locale for the listing text, default is the app's primary locale")
    app.add_argument("--set-version", default="auto",
                     help="auto (default): take the version from the newest valid build. keep: leave the "
                          "version string alone. Or a version such as 0.1.5")
    app.add_argument("--build-version", default=None,
                     help="with --set-version auto, choose among the builds of this version")
    app.add_argument("--territories", default="all",
                     help="all (default) or a comma separated list of territory codes such as USA,IRL")
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
    try:
        if args.locale and not LOCALE_RE.match(args.locale):
            raise ConfigError("--locale must look like en-GB")
    except ConfigError as exc:
        out.raw("ERROR configuration: %s" % exc)
        return 2
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
            if args.set_version not in ("auto", "keep") and not VERSION_RE.match(args.set_version):
                raise ConfigError("--set-version must be auto, keep or a version such as 0.1.5")
            if args.build_version and not VERSION_RE.match(args.build_version):
                raise ConfigError("--build-version must be a version such as 0.1.5")
            if not re.match(r"^(all|[A-Z]{3}(,[A-Z]{3})*)$", args.territories):
                raise ConfigError("--territories must be all or a list of 3 letter codes such as USA,IRL")
        except ConfigError as exc:
            out.raw("ERROR configuration: %s" % exc)
            return 2
        contact = contact_from_env()
        for value in (contact or {}).values():
            out.add_secret(value)
    try:
        if args.command == "check":
            code = run_check(api, out, bundle, listing, locale=args.locale)
            out.write_summary("App Store Connect check")
            return code
        code = run_apply(api, out, bundle, listing, steps=steps, build_number=build_number,
                         screenshots_dir=args.screenshots_dir,
                         replace_screenshots=args.replace_screenshots,
                         base_territory=args.base_territory, contact=contact,
                         sleep=sleep, clock=clock, locale=args.locale, set_version=args.set_version,
                         build_version=args.build_version, territories=args.territories)
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
    except AscError as exc:
        out.raw("ERROR api: %s" % exc.describe())
        return 2 if args.command == "check" else 1
    except Exception as exc:  # noqa: BLE001 - never let a traceback reach a public log
        out.raw("ERROR unexpected: %s" % type(exc).__name__)
        return 2 if args.command == "check" else 1


if __name__ == "__main__":
    sys.exit(main())
