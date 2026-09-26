#!/usr/bin/env python3
"""Tests for asc_tool.py. Fake values and a fake HTTP layer only. No network."""
import base64
import io
import json
import os
import sys
import tempfile
import unittest
import urllib.error

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import asc_tool as t  # noqa: E402

from cryptography.hazmat.primitives import hashes, serialization  # noqa: E402
from cryptography.hazmat.primitives.asymmetric import ec  # noqa: E402
from cryptography.hazmat.primitives.asymmetric.utils import encode_dss_signature  # noqa: E402

# Fake identifiers built from parts so secret scanners see no real shapes.
FAKE_KEY_ID = "FAKE" + "KEY" + "001"
FAKE_ISSUER = "00000000-0000-0000-0000-" + "000000000001"
FAKE_BUNDLE = "test.example.fakeapp"


def new_key():
    return ec.generate_private_key(ec.SECP256R1())


def b64url_decode(text):
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


class Clock:
    def __init__(self, start=1_800_000_000.0):
        self.now = start
        self.slept = []

    def time(self):
        return self.now

    def sleep(self, seconds):
        self.slept.append(seconds)
        self.now += seconds


def json_bytes(doc):
    return json.dumps(doc).encode()


class ScriptedTransport:
    """Return queued (status, headers, body) tuples or raise queued exceptions."""

    def __init__(self, replies):
        self.replies = list(replies)
        self.calls = []

    def __call__(self, method, url, headers, body, timeout):
        self.calls.append((method, url, dict(headers), body))
        item = self.replies.pop(0)
        if isinstance(item, Exception):
            raise item
        return item


def make_api(replies, key=None, **kw):
    clock = Clock()
    transport = ScriptedTransport(replies)
    api = t.Api(FAKE_KEY_ID, FAKE_ISSUER, key or new_key(), transport=transport,
                sleep=clock.sleep, clock=clock.time, **kw)
    return api, transport, clock


class JwtTests(unittest.TestCase):
    def test_structure_and_signature(self):
        key = new_key()
        token = t.make_jwt(FAKE_KEY_ID, FAKE_ISSUER, key, 1_800_000_000)
        head, claims, sig = token.split(".")
        header = json.loads(b64url_decode(head))
        body = json.loads(b64url_decode(claims))
        self.assertEqual(header["alg"], "ES256")
        self.assertEqual(header["kid"], FAKE_KEY_ID)
        self.assertEqual(header["typ"], "JWT")
        self.assertEqual(body["iss"], FAKE_ISSUER)
        self.assertEqual(body["aud"], "appstoreconnect-v1")
        self.assertEqual(body["iat"], 1_800_000_000)
        self.assertLessEqual(body["exp"] - body["iat"], 600)
        self.assertGreater(body["exp"], body["iat"])
        raw = b64url_decode(sig)
        self.assertEqual(len(raw), 64)
        der = encode_dss_signature(int.from_bytes(raw[:32], "big"), int.from_bytes(raw[32:], "big"))
        key.public_key().verify(der, (head + "." + claims).encode(), ec.ECDSA(hashes.SHA256()))

    def test_signature_fails_with_other_key(self):
        token = t.make_jwt(FAKE_KEY_ID, FAKE_ISSUER, new_key(), 1_800_000_000)
        head, claims, sig = token.split(".")
        raw = b64url_decode(sig)
        der = encode_dss_signature(int.from_bytes(raw[:32], "big"), int.from_bytes(raw[32:], "big"))
        with self.assertRaises(Exception):
            new_key().public_key().verify(der, (head + "." + claims).encode(), ec.ECDSA(hashes.SHA256()))

    def test_token_cached_then_refreshed(self):
        api, _tr, clock = make_api([])
        first = api.token()
        self.assertEqual(first, api.token())
        clock.now += 600
        self.assertNotEqual(first, api.token())

    def test_load_private_key_rejects_junk(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "k.p8")
            with open(path, "wb") as fh:
                fh.write(b"not a key")
            with self.assertRaises(t.ConfigError):
                t.load_private_key(path)

    def test_load_private_key_accepts_p256_and_rejects_rsa(self):
        from cryptography.hazmat.primitives.asymmetric import rsa
        with tempfile.TemporaryDirectory() as tmp:
            good = os.path.join(tmp, "good.p8")
            with open(good, "wb") as fh:
                fh.write(new_key().private_bytes(serialization.Encoding.PEM,
                                                 serialization.PrivateFormat.PKCS8,
                                                 serialization.NoEncryption()))
            self.assertEqual(t.load_private_key(good).curve.name, "secp256r1")
            bad = os.path.join(tmp, "bad.p8")
            with open(bad, "wb") as fh:
                fh.write(rsa.generate_private_key(65537, 2048).private_bytes(
                    serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                    serialization.NoEncryption()))
            with self.assertRaises(t.ConfigError):
                t.load_private_key(bad)


class HttpTests(unittest.TestCase):
    def test_request_sends_bearer_and_json_body(self):
        api, tr, _c = make_api([(200, {}, json_bytes({"data": {"id": "1"}}))])
        out = api.post("/v1/things", {"data": {"type": "things"}})
        self.assertEqual(out["data"]["id"], "1")
        method, url, headers, body = tr.calls[0]
        self.assertEqual(method, "POST")
        self.assertEqual(url, t.API_BASE + "/v1/things")
        self.assertTrue(headers["Authorization"].startswith("Bearer "))
        self.assertEqual(headers["Content-Type"], "application/json")
        self.assertEqual(json.loads(body), {"data": {"type": "things"}})

    def test_query_parameters(self):
        api, tr, _c = make_api([(200, {}, json_bytes({"data": []}))])
        api.get("/v1/apps", {"filter[bundleId]": "a.b.c", "limit": 2})
        self.assertIn("filter[bundleId]=a.b.c", tr.calls[0][1])
        self.assertIn("limit=2", tr.calls[0][1])

    def test_retry_on_429_and_5xx_with_backoff(self):
        api, tr, clock = make_api([
            (429, {"Retry-After": "3"}, b""),
            (503, {}, b""),
            (500, {}, b""),
            (200, {}, json_bytes({"data": []})),
        ])
        self.assertEqual(api.get("/v1/apps"), {"data": []})
        self.assertEqual(len(tr.calls), 4)
        self.assertEqual(clock.slept, [3.0, 2, 4])

    def test_retry_gives_up_and_raises(self):
        api, tr, _c = make_api([(503, {}, json_bytes({"errors": [{"code": "X", "title": "down"}]}))] * 5)
        with self.assertRaises(t.AscError) as ctx:
            api.get("/v1/apps")
        self.assertEqual(ctx.exception.status, 503)
        self.assertEqual(len(tr.calls), 5)

    def test_no_retry_on_client_error(self):
        api, tr, _c = make_api([(409, {}, json_bytes({"errors": [{"code": "STATE_ERROR", "title": "Bad", "detail": "no"}]}))])
        with self.assertRaises(t.AscError) as ctx:
            api.get("/v1/apps")
        self.assertEqual(len(tr.calls), 1)
        self.assertIn("STATE_ERROR", ctx.exception.describe())

    def test_network_error_retried_then_raised(self):
        api, tr, _c = make_api([urllib.error.URLError("down")] * 5)
        with self.assertRaises(t.NetworkError):
            api.get("/v1/apps")
        self.assertEqual(len(tr.calls), 5)

    def test_network_error_then_success(self):
        api, _tr, _c = make_api([TimeoutError(), (200, {}, json_bytes({"data": []}))])
        self.assertEqual(api.get("/v1/apps"), {"data": []})

    def test_global_deadline(self):
        api, _tr, clock = make_api([(200, {}, b"{}")], deadline=10)
        clock.now += 11
        with self.assertRaises(t.NetworkError):
            api.get("/v1/apps")

    def test_pagination_follows_next_and_merges_included(self):
        page2 = t.API_BASE + "/v1/apps?cursor=abc"
        api, tr, _c = make_api([
            (200, {}, json_bytes({"data": [{"id": "a"}], "included": [{"id": "i1"}], "links": {"next": page2}})),
            (200, {}, json_bytes({"data": [{"id": "b"}], "included": [{"id": "i2"}], "links": {}})),
        ])
        data, included = api.get_all("/v1/apps", {"limit": 1})
        self.assertEqual([d["id"] for d in data], ["a", "b"])
        self.assertEqual([d["id"] for d in included], ["i1", "i2"])
        self.assertEqual(tr.calls[1][1], page2)

    def test_pagination_refuses_other_host(self):
        api, _tr, _c = make_api([
            (200, {}, json_bytes({"data": [], "links": {"next": "https://evil.example.test/x"}})),
        ])
        with self.assertRaises(t.ConfigError):
            api.get_all("/v1/apps")

    def test_put_part_has_no_credentials_and_needs_https(self):
        api, tr, _c = make_api([(200, {}, b"")])
        api.put_part("PUT", "https://upload.example.test/part", {"Content-Type": "image/png"}, b"abc")
        self.assertNotIn("Authorization", tr.calls[0][2])
        with self.assertRaises(t.ConfigError):
            api.put_part("PUT", "http://upload.example.test/part", {}, b"abc")

    def test_put_part_error(self):
        api, _tr, _c = make_api([(403, {}, b"")])
        with self.assertRaises(t.AscError):
            api.put_part("PUT", "https://upload.example.test/part", {}, b"abc")


class SanitiserTests(unittest.TestCase):
    def setUp(self):
        self.out = t.Out(stream=io.StringIO(), secrets=[FAKE_KEY_ID, FAKE_ISSUER, FAKE_BUNDLE])

    def test_registered_secrets_removed(self):
        text = self.out.clean("key %s issuer %s bundle %s" % (FAKE_KEY_ID, FAKE_ISSUER, FAKE_BUNDLE))
        for value in (FAKE_KEY_ID, FAKE_ISSUER, FAKE_BUNDLE):
            self.assertNotIn(value, text)

    def test_shapes_removed(self):
        samples = [
            "user@example.test", "12345678-90ab-cdef-1234-567890abcdef", "0123456789abcdef0123",
            "1234567890", "AB12CD34EF", "eyJhbGciOiJFUzI1NiJ9.eyJpc3MiOiJ4In0.c2ln",
            "+353 1 555 0100", "QWxhZGRpbjpvcGVuIHNlc2FtZQ12345",
        ]
        for sample in samples:
            cleaned = self.out.clean("detail " + sample + " end")
            self.assertNotIn(sample, cleaned, sample)
            self.assertIn("detail", cleaned)

    def test_ordinary_text_kept(self):
        for keep in ("PASS description: 812/4000 characters", "1290x2796", "build 42 of version 1.0",
                     "APP_IPHONE_67", "DEVELOPER_TOOLS", "PREPARE_FOR_SUBMISSION"):
            self.assertEqual(self.out.clean(keep), keep)

    def test_phone_digits_registered(self):
        out = t.Out(stream=io.StringIO(), secrets=["+1 (555) 010-0199"])
        self.assertNotIn("5550100199", out.clean("call 5550100199 now"))
        self.assertNotIn("+1 (555) 010-0199", out.clean("call +1 (555) 010-0199 now"))

    def test_error_describe_is_sanitised_by_out(self):
        err = t.AscError(409, [{"code": "ENTITY_ERROR", "title": "Bad",
                                "detail": "app %s owned by boss@example.test id 1234567890" % FAKE_BUNDLE}])
        self.out.raw(err.describe())
        line = self.out.lines[-1]
        self.assertNotIn(FAKE_BUNDLE, line)
        self.assertNotIn("boss@example.test", line)
        self.assertNotIn("1234567890", line)
        self.assertIn("ENTITY_ERROR", line)

    def test_summary_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "summary.md")
            self.out.raw("PASS thing: %s" % FAKE_KEY_ID)
            self.out.write_summary("Title", path)
            with open(path, encoding="utf-8") as fh:
                text = fh.read()
            self.assertIn("PASS thing", text)
            self.assertNotIn(FAKE_KEY_ID, text)


import fake_asc  # noqa: E402

LISTING_PATH = os.path.join(HERE, "testdata", "listing.json")
CONTACT = {
    "REVIEW_CONTACT_FIRST_NAME": "Fakefirst",
    "REVIEW_CONTACT_LAST_NAME": "Fakelast",
    "REVIEW_CONTACT_PHONE": "+1 555 010 0199",
    "REVIEW_CONTACT_EMAIL": "contact@example.test",
}
ENV_NAMES = ("ASC_API_KEY_ID", "ASC_API_ISSUER_ID", "ASC_API_KEY_P8_PATH", "APP_BUNDLE_ID") + t.REVIEW_CONTACT_ENV


class ToolRun:
    """Run t.main against a fake with a temporary key file and environment."""

    def __init__(self, contact=None, key_id=FAKE_KEY_ID):
        self.key = new_key()
        self.tmp = tempfile.TemporaryDirectory()
        self.key_path = os.path.join(self.tmp.name, "key.p8")
        with open(self.key_path, "wb") as fh:
            fh.write(self.key.private_bytes(serialization.Encoding.PEM,
                                            serialization.PrivateFormat.PKCS8,
                                            serialization.NoEncryption()))
        self.env = {"ASC_API_KEY_ID": key_id, "ASC_API_ISSUER_ID": FAKE_ISSUER,
                    "ASC_API_KEY_P8_PATH": self.key_path, "APP_BUNDLE_ID": FAKE_BUNDLE}
        self.env.update(contact or {})
        self.saved = {}

    def fake(self, complete=True, **kw):
        return fake_asc.build_app(FAKE_BUNDLE, public_key=self.key.public_key(), complete=complete, **kw)

    def run(self, transport, argv, summary=None):
        self.saved = {n: os.environ.get(n) for n in ENV_NAMES + ("GITHUB_STEP_SUMMARY",)}
        for name in ENV_NAMES:
            os.environ.pop(name, None)
        os.environ.update(self.env)
        if summary:
            os.environ["GITHUB_STEP_SUMMARY"] = summary
        else:
            os.environ.pop("GITHUB_STEP_SUMMARY", None)
        stream = io.StringIO()
        clock = Clock()
        try:
            code = t.main(argv, transport=transport, sleep=clock.sleep, clock=clock.time, stream=stream)
        finally:
            for name, value in self.saved.items():
                if value is None:
                    os.environ.pop(name, None)
                else:
                    os.environ[name] = value
        return code, stream.getvalue().splitlines()

    def close(self):
        self.tmp.cleanup()


class CheckTests(unittest.TestCase):
    def setUp(self):
        self.tool = ToolRun(CONTACT)
        self.addCleanup(self.tool.close)

    def check(self, fake, argv=None):
        return self.tool.run(fake, argv or ["check", "--listing", LISTING_PATH])

    def statuses(self, lines, kind):
        return [l for l in lines if l.startswith(kind + " ")]

    def test_complete_app_has_nothing_missing(self):
        fake = self.tool.fake()
        code, lines = self.check(fake)
        self.assertEqual(code, 0)
        self.assertEqual(self.statuses(lines, "MISSING"), [], "\n".join(lines))
        self.assertIn("PASS app record: found by bundle id", lines)
        self.assertIn("PASS editable version: 1.0, state PREPARE_FOR_SUBMISSION", lines)
        self.assertIn("PASS build attached: build 7, version 1.0, processing VALID", lines)
        self.assertIn("PASS newest processed build: build 7 matches version 1.0", lines)
        self.assertTrue(any(l.startswith("PASS screenshots en-US iPhone 6.9 inch: 2 in APP_IPHONE_67") for l in lines))
        self.assertTrue(any(l.startswith("PASS screenshots en-US iPad 13 inch: 2 in APP_IPAD_PRO_3GEN_129") for l in lines))
        self.assertIn("PASS price schedule: set, Free", lines)
        self.assertIn("PASS availability: 3 territories", lines)
        self.assertEqual(len(self.statuses(lines, "MANUAL")), 3)
        self.assertIn("MANUAL App Privacy questionnaire: answer Data Not Collected in App Store Connect, App Privacy", lines)
        self.assertIn("MANUAL Press Submit for Review", lines)
        self.assertTrue(lines[-1].startswith("RESULT: nothing missing"))
        self.assertEqual([e["method"] for e in fake.log if e["method"] != "GET"], [])

    def test_every_request_is_signed_and_read_only(self):
        fake = self.tool.fake()
        self.check(fake)
        self.assertGreater(len(fake.log), 10)
        self.assertEqual({e["method"] for e in fake.log}, {"GET"})

    def test_missing_localisation(self):
        fake = self.tool.fake()
        fake.db["appStoreVersionLocalizations"].clear()
        code, lines = self.check(fake)
        self.assertEqual(code, 0)
        self.assertIn("MISSING version localisation en-US: does not exist: run apply", lines)
        self.assertTrue(any(l.startswith("MISSING screenshots en-US") for l in lines))

    def test_localisation_fields_and_limits(self):
        fake = self.tool.fake()
        loc = fake.all("appStoreVersionLocalizations")[0]
        loc["attributes"].update({"description": "", "keywords": "k" * 101, "supportUrl": ""})
        _c, lines = self.check(fake)
        self.assertTrue(any(l.startswith("MISSING version localisation en-US description") for l in lines))
        self.assertIn("MISSING version localisation en-US keywords: 101 characters, the limit is 100", lines)
        self.assertTrue(any(l.startswith("MISSING version localisation en-US support URL") for l in lines))
        self.assertIn("PASS version localisation en-US promotional text: 5/170 characters", lines)

    def test_no_build(self):
        fake = self.tool.fake()
        fake.all("appStoreVersions")[0]["rels"].pop("build")
        fake.db["builds"].clear()
        _c, lines = self.check(fake)
        self.assertTrue(any(l.startswith("MISSING build attached: no build is attached") for l in lines))
        self.assertTrue(any(l.startswith("MISSING newest processed build: no valid build for version 1.0") for l in lines))

    def test_build_still_processing(self):
        fake = self.tool.fake()
        fake.all("builds")[0]["attributes"]["processingState"] = "PROCESSING"
        _c, lines = self.check(fake)
        self.assertIn("MISSING build attached: build 7 is attached but its processing state is PROCESSING", lines)
        self.assertTrue(any("1 processing" in l for l in lines))

    def test_wrong_build_for_other_version(self):
        fake = self.tool.fake()
        old = fake.add("preReleaseVersions", {"version": "0.9"}, parent="900001")
        fake.all("builds")[0]["rels"]["preReleaseVersion"] = {"type": "preReleaseVersions", "id": old["id"]}
        _c, lines = self.check(fake)
        self.assertIn("MISSING build attached: the attached build 7 is not a build of version 1.0: run apply", lines)
        self.assertTrue(any(l.startswith("MISSING newest processed build") for l in lines))

    def test_newer_build_is_reported(self):
        fake = self.tool.fake()
        pre = fake.all("preReleaseVersions")[0]
        fake.add("builds", {"version": "8", "processingState": "VALID", "expired": False,
                            "uploadedDate": "2026-09-02T10:00:00Z", "usesNonExemptEncryption": True},
                 parent="900001", rels={"preReleaseVersion": {"type": "preReleaseVersions", "id": pre["id"]}})
        _c, lines = self.check(fake)
        self.assertIn("INFO newest build: build 8 is newer and valid, the attached build is 7", lines)

    def test_screenshots_missing_and_too_many(self):
        fake = self.tool.fake()
        sets = fake.all("appScreenshotSets")
        for shot in list(fake.all("appScreenshots", sets[1]["id"])):
            del fake.db["appScreenshots"][shot["id"]]
        for i in range(11):
            fake.add("appScreenshots", {"fileName": "x%02d.png" % i, "assetDeliveryState": {"state": "COMPLETE"}},
                     parent=sets[0]["id"])
        _c, lines = self.check(fake)
        self.assertTrue(any(l.startswith("MISSING screenshots en-US iPad 13 inch: none uploaded") for l in lines))
        self.assertIn("MISSING screenshots en-US iPhone 6.9 inch: 13 screenshots in APP_IPHONE_67, the maximum is 10", lines)

    def test_screenshot_not_complete(self):
        fake = self.tool.fake()
        shot = fake.all("appScreenshots")[0]
        shot["attributes"]["assetDeliveryState"]["state"] = "UPLOAD_COMPLETE"
        _c, lines = self.check(fake)
        self.assertTrue(any("are not COMPLETE yet" in l for l in lines))

    def test_fresh_app_lists_everything_to_do(self):
        fake = self.tool.fake(complete=False)
        code, lines = self.check(fake)
        self.assertEqual(code, 0)
        missing = "\n".join(self.statuses(lines, "MISSING"))
        for word in ("content rights declaration", "copyright", "build attached", "version localisation en-US",
                     "app info localisation en-US", "primary category", "age rating", "app review details",
                     "screenshots en-US", "price schedule", "availability"):
            self.assertIn(word, missing)

    def test_age_rating_uses_listing_keys(self):
        fake = self.tool.fake()
        decl = fake.all("ageRatingDeclarations")[0]
        decl["attributes"]["gambling"] = None
        _c, lines = self.check(fake)
        self.assertTrue(any(l.startswith("MISSING age rating: 1 answer(s) not set (gambling)") for l in lines))

    def test_review_contact_missing_names_secret_only(self):
        fake = self.tool.fake()
        detail = fake.all("appStoreReviewDetails")[0]
        detail["attributes"].update({"contactPhone": None, "contactEmail": ""})
        _c, lines = self.check(fake)
        text = "\n".join(lines)
        self.assertIn("MISSING app review contact phone: empty: add the REVIEW_CONTACT_PHONE secret", text)
        self.assertIn("MISSING app review contact email", text)
        self.assertIn("PASS app review contact first name: present", lines)
        self.assertNotIn("Fakefirst", text)
        self.assertNotIn("+353", text)
        self.assertNotIn("test@example.test", text)

    def test_demo_account_required_without_credentials(self):
        fake = self.tool.fake()
        fake.all("appStoreReviewDetails")[0]["attributes"]["demoAccountRequired"] = True
        _c, lines = self.check(fake)
        self.assertTrue(any(l.startswith("MISSING app review demo account: required but") for l in lines))

    def test_no_price_and_paid_price(self):
        fake = self.tool.fake()
        fake.db["appPriceSchedules"].clear()
        _c, lines = self.check(fake)
        self.assertTrue(any(l.startswith("MISSING price schedule: not set") for l in lines))
        fake = self.tool.fake()
        price = fake.all("appPrices")[0]
        price["rels"]["appPricePoint"] = {"type": "appPricePoints", "id": "pp-paid"}
        _c, lines = self.check(fake)
        self.assertIn("INFO price schedule: set, not Free", lines)

    def test_no_editable_version(self):
        fake = self.tool.fake()
        fake.all("appStoreVersions")[0]["attributes"]["appVersionState"] = "WAITING_FOR_REVIEW"
        _c, lines = self.check(fake)
        self.assertTrue(any(l.startswith("MISSING editable version: no version can be edited (states: WAITING_FOR_REVIEW)") for l in lines))

    def test_no_app_record(self):
        fake = self.tool.fake()
        fake.db["apps"].clear()
        code, lines = self.check(fake)
        self.assertEqual(code, 0)
        self.assertTrue(any(l.startswith("MISSING app record") for l in lines))
        self.assertEqual(len(self.statuses(lines, "MANUAL")), 3)

    def test_one_forbidden_read_is_info_not_failure(self):
        fake = self.tool.fake()
        fake.failures.append(("GET", r"appAvailabilityV2", 403, [{"code": "FORBIDDEN_ERROR", "title": "Forbidden", "detail": "no access"}]))
        code, lines = self.check(fake)
        self.assertEqual(code, 0)
        self.assertTrue(any(l.startswith("INFO availability: could not be read: HTTP 403 | FORBIDDEN_ERROR") for l in lines))
        self.assertEqual(self.statuses(lines, "MISSING"), [])

    def test_rejected_credentials_exit_2(self):
        fake = self.tool.fake()
        fake.public_key = new_key().public_key()  # signature no longer verifies
        code, lines = self.check(fake)
        self.assertEqual(code, 2)
        self.assertTrue(any(l.startswith("ERROR credentials:") for l in lines))

    def test_forbidden_first_call_exit_2(self):
        fake = self.tool.fake()
        fake.failures.append(("GET", r"^/v1/apps$", 403, [{"code": "FORBIDDEN_ERROR", "title": "Forbidden", "detail": "role"}]))
        code, lines = self.check(fake)
        self.assertEqual(code, 2)

    def test_server_error_on_first_call_exit_2_without_traceback(self):
        fake = self.tool.fake()
        fake.failures.append(("GET", r"^/v1/apps$", 500, [{"code": "UNEXPECTED_ERROR", "title": "Oops"}]))
        code, lines = self.check(fake)
        self.assertEqual(code, 2)
        self.assertTrue(any(l.startswith("ERROR api: HTTP 500") for l in lines))
        self.assertFalse(any("Traceback" in l for l in lines))

    def test_unexpected_exception_prints_type_only(self):
        def broken(*_a):
            raise RuntimeError("secret detail " + FAKE_BUNDLE)
        code, lines = self.tool.run(broken, ["check"])
        self.assertEqual(code, 2)
        self.assertEqual(lines, ["ERROR unexpected: RuntimeError"])

    def test_unreachable_exit_2(self):
        def down(*_a):
            raise urllib.error.URLError("down")
        code, lines = self.tool.run(down, ["check"])
        self.assertEqual(code, 2)
        self.assertTrue(any(l.startswith("ERROR network:") for l in lines))

    def test_bad_configuration_exit_2(self):
        tool = ToolRun(key_id="short")
        self.addCleanup(tool.close)
        code, lines = tool.run(tool.fake(), ["check"])
        self.assertEqual(code, 2)
        self.assertTrue(any("ASC_API_KEY_ID" in l for l in lines))

    def test_invalid_listing_is_ignored_for_check(self):
        bad = os.path.join(self.tool.tmp.name, "bad.json")
        with open(bad, "w", encoding="utf-8") as fh:
            fh.write('{"name": "' + "n" * 40 + '"}')
        code, lines = self.check(self.tool.fake(), ["check", "--listing", bad])
        self.assertEqual(code, 0)
        self.assertTrue(any(l.startswith("ERROR listing: name: 40 characters") for l in lines))

    def test_no_secret_in_any_line_even_when_the_api_echoes_it(self):
        fake = self.tool.fake()
        echo = {"code": "ENTITY_ERROR", "title": "Bad", "detail": "app %s, key %s, issuer %s, mail %s phone %s id 1234567890" % (
            FAKE_BUNDLE, FAKE_KEY_ID, FAKE_ISSUER, CONTACT["REVIEW_CONTACT_EMAIL"], CONTACT["REVIEW_CONTACT_PHONE"])}
        fake.failures.append(("GET", r"appPriceSchedule$", 500, [echo]))
        fake.failures.append(("GET", r"appAvailabilityV2", 400, [echo]))
        tool_env = dict(CONTACT)
        code, lines = self.check(fake)
        self.assertEqual(code, 0)
        blob = "\n".join(lines)
        for secret in [FAKE_BUNDLE, FAKE_KEY_ID, FAKE_ISSUER, "1234567890", "555 010 0199", "5550100199"] + list(tool_env.values()):
            self.assertNotIn(secret, blob)
        self.assertIn("ENTITY_ERROR", blob)

    def test_summary_file_written_without_secrets(self):
        fake = self.tool.fake()
        summary = os.path.join(self.tool.tmp.name, "summary.md")
        code, _lines = self.tool.run(fake, ["check", "--listing", LISTING_PATH], summary=summary)
        self.assertEqual(code, 0)
        with open(summary, encoding="utf-8") as fh:
            text = fh.read()
        self.assertIn("PASS app record", text)
        self.assertIn("MANUAL Press Submit for Review", text)
        for secret in (FAKE_BUNDLE, FAKE_KEY_ID, FAKE_ISSUER):
            self.assertNotIn(secret, text)

    def test_all_lines_use_a_known_prefix(self):
        _c, lines = self.check(self.tool.fake(complete=False))
        for line in lines:
            self.assertRegex(line, r"^(PASS|MISSING|INFO|MANUAL|RESULT|ERROR|SET|SKIP|FAIL)\b", line)


class ApplyTests(unittest.TestCase):
    def setUp(self):
        self.tool = ToolRun(CONTACT)
        self.addCleanup(self.tool.close)

    def apply(self, fake, extra=None, listing=LISTING_PATH):
        return self.tool.run(fake, ["apply", "--listing", listing] + (extra or []))

    @staticmethod
    def writes(fake):
        return [e for e in fake.log if e["method"] != "GET"]

    def listing_copy(self, **changes):
        with open(LISTING_PATH, encoding="utf-8") as fh:
            doc = json.load(fh)
        doc.update(changes)
        path = os.path.join(self.tool.tmp.name, "listing-%d.json" % len(os.listdir(self.tool.tmp.name)))
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(doc, fh)
        return path

    def test_fresh_app_gets_every_write_in_order(self):
        fake = self.tool.fake(complete=False)
        vid = fake.all("appStoreVersions")[0]["id"]
        iid = fake.all("appInfos")[0]["id"]
        decl = fake.all("ageRatingDeclarations")[0]["id"]
        build = fake.all("builds")[0]["id"]
        code, lines = self.apply(fake)
        self.assertEqual(code, 0, "\n".join(lines))
        seq = [(e["method"], e["path"]) for e in self.writes(fake)]
        self.assertEqual(seq, [
            ("POST", "/v1/appStoreVersionLocalizations"),
            ("POST", "/v1/appInfoLocalizations"),
            ("PATCH", "/v1/appInfos/%s" % iid),
            ("PATCH", "/v1/appStoreVersions/%s" % vid),
            ("PATCH", "/v1/ageRatingDeclarations/%s" % decl),
            ("PATCH", "/v1/apps/900001"),
            ("PATCH", "/v1/appStoreVersions/%s/relationships/build" % vid),
            ("POST", "/v1/appStoreReviewDetails"),
            ("POST", "/v1/appPriceSchedules"),
            ("POST", "/v2/appAvailabilities"),
        ])
        bodies = [e["body"] for e in self.writes(fake)]
        loc = bodies[0]["data"]
        self.assertEqual(loc["type"], "appStoreVersionLocalizations")
        self.assertEqual(loc["relationships"]["appStoreVersion"]["data"], {"type": "appStoreVersions", "id": vid})
        self.assertEqual(loc["attributes"]["locale"], "en-US")
        self.assertEqual(sorted(loc["attributes"]),
                         ["description", "keywords", "locale", "marketingUrl", "promotionalText", "supportUrl"])
        info_loc = bodies[1]["data"]
        self.assertEqual(info_loc["relationships"]["appInfo"]["data"], {"type": "appInfos", "id": iid})
        self.assertEqual(sorted(info_loc["attributes"]), ["locale", "name", "privacyPolicyUrl", "subtitle"])
        self.assertEqual(bodies[2]["data"]["relationships"], {
            "primaryCategory": {"data": {"type": "appCategories", "id": "DEVELOPER_TOOLS"}},
            "secondaryCategory": {"data": {"type": "appCategories", "id": "PRODUCTIVITY"}}})
        self.assertEqual(bodies[3]["data"], {"type": "appStoreVersions", "id": vid,
                                             "attributes": {"copyright": "2026 Example Test"}})
        self.assertEqual(bodies[4]["data"]["type"], "ageRatingDeclarations")
        self.assertEqual(bodies[4]["data"]["attributes"]["violenceRealistic"], "NONE")
        self.assertIs(bodies[4]["data"]["attributes"]["advertising"], False)
        self.assertEqual(bodies[5]["data"]["attributes"],
                         {"contentRightsDeclaration": "DOES_NOT_USE_THIRD_PARTY_CONTENT"})
        self.assertEqual(bodies[6], {"data": {"type": "builds", "id": build}})
        review = bodies[7]["data"]
        self.assertEqual(review["relationships"]["appStoreVersion"]["data"], {"type": "appStoreVersions", "id": vid})
        self.assertEqual(sorted(review["attributes"]), sorted([
            "notes", "demoAccountRequired", "contactFirstName", "contactLastName", "contactPhone", "contactEmail"]))
        self.assertIs(review["attributes"]["demoAccountRequired"], False)
        price = bodies[8]
        self.assertEqual(price["data"]["relationships"]["app"]["data"], {"type": "apps", "id": "900001"})
        self.assertEqual(price["data"]["relationships"]["baseTerritory"]["data"], {"type": "territories", "id": "USA"})
        ref = price["data"]["relationships"]["manualPrices"]["data"][0]
        self.assertEqual(price["included"][0]["id"], ref["id"])
        self.assertRegex(price["included"][0]["attributes"]["startDate"], r"^\d{4}-\d{2}-\d{2}$")
        self.assertEqual(price["included"][0]["relationships"]["appPricePoint"]["data"],
                         {"type": "appPricePoints", "id": "pp-free"})

    def test_what_is_new_skipped_for_first_version_and_sent_for_updates(self):
        fake = self.tool.fake(complete=False)
        _c, lines = self.apply(fake)
        self.assertTrue(any("what's new is not set because this is the first version" in l for l in lines))
        self.assertNotIn("whatsNew", json.dumps([e["body"] for e in self.writes(fake)]))
        fake = self.tool.fake(complete=False)
        fake.add("appStoreVersions", {"versionString": "0.9", "platform": "IOS", "appVersionState": "READY_FOR_SALE"},
                 parent="900001")
        code, _lines = self.apply(fake)
        self.assertEqual(code, 0)
        first = self.writes(fake)[0]["body"]["data"]["attributes"]
        self.assertEqual(first["whatsNew"], "Placeholder release notes for tests.")

    def test_apply_is_idempotent_and_check_is_clean_after(self):
        fake = self.tool.fake(complete=False)
        self.assertEqual(self.apply(fake)[0], 0)
        first_writes = len(self.writes(fake))
        code, lines = self.apply(fake)
        self.assertEqual(code, 0)
        self.assertEqual(len(self.writes(fake)), first_writes, "second run wrote again")
        self.assertEqual([l for l in lines if l.startswith("SET ")], [], "\n".join(lines))
        self.assertTrue(any(l.startswith("SKIP version localisation en-US: already up to date") for l in lines))
        _c, chk = self.tool.run(fake, ["check", "--listing", LISTING_PATH])
        missing = [l.split(":")[0] for l in chk if l.startswith("MISSING")]
        self.assertEqual(sorted(missing), [
            "MISSING screenshots en-US iPad 13 inch", "MISSING screenshots en-US iPhone 6.9 inch"])

    def test_update_only_sends_changed_fields(self):
        fake = self.tool.fake()
        loc = fake.all("appStoreVersionLocalizations")[0]
        loc["attributes"].update({"description": "Old text", "keywords": "test,placeholder,example",
                                  "promotionalText": "Placeholder promotional text for tests.",
                                  "supportUrl": "https://example.test/support", "marketingUrl": "https://example.test/"})
        code, lines = self.apply(fake)
        self.assertEqual(code, 0, "\n".join(lines))
        patches = [e for e in self.writes(fake) if e["path"].startswith("/v1/appStoreVersionLocalizations/")]
        self.assertEqual(len(patches), 1)
        self.assertEqual(patches[0]["body"]["data"]["attributes"], {
            "description": "Placeholder description text for tests only.\n\nSecond paragraph of placeholder text."})
        self.assertIn("SET version localisation en-US: updated: description", lines)

    def test_no_contact_secrets_skips_contact_and_never_writes_them(self):
        tool = ToolRun(None)
        self.addCleanup(tool.close)
        fake = tool.fake(complete=False)
        code, lines = tool.run(fake, ["apply", "--listing", LISTING_PATH])
        self.assertEqual(code, 0)
        self.assertTrue(any(l.startswith("SKIP review contact: the REVIEW_CONTACT_* secrets are not all set") for l in lines))
        review = [e for e in self.writes(fake) if "appStoreReviewDetails" in e["path"]]
        self.assertEqual(sorted(review[0]["body"]["data"]["attributes"]), ["demoAccountRequired", "notes"])

    def test_partial_contact_secrets_count_as_absent(self):
        partial = dict(CONTACT)
        del partial["REVIEW_CONTACT_PHONE"]
        tool = ToolRun(partial)
        self.addCleanup(tool.close)
        fake = tool.fake(complete=False)
        _c, lines = tool.run(fake, ["apply", "--listing", LISTING_PATH])
        self.assertTrue(any(l.startswith("SKIP review contact") for l in lines))
        self.assertNotIn("Fakefirst", json.dumps([e["body"] for e in self.writes(fake)]))

    def test_contact_values_never_in_output(self):
        fake = self.tool.fake(complete=False)
        _c, lines = self.apply(fake)
        blob = "\n".join(lines)
        for value in CONTACT.values():
            self.assertNotIn(value, blob)
        self.assertIn("SET app review details: created: contactEmail, contactFirstName, contactLastName, contactPhone, demoAccountRequired, notes", lines)

    def test_build_choice(self):
        fake = self.tool.fake(complete=False)
        pre = fake.all("preReleaseVersions")[0]
        rel = {"preReleaseVersion": {"type": "preReleaseVersions", "id": pre["id"]}}
        b8 = fake.add("builds", {"version": "8", "processingState": "VALID", "expired": False,
                                 "uploadedDate": "2026-09-02T10:00:00Z"}, parent="900001", rels=rel)
        fake.add("builds", {"version": "9", "processingState": "PROCESSING", "expired": False,
                            "uploadedDate": "2026-09-03T10:00:00Z"}, parent="900001", rels=rel)
        other = fake.add("preReleaseVersions", {"version": "2.0"}, parent="900001")
        fake.add("builds", {"version": "10", "processingState": "VALID", "expired": False,
                            "uploadedDate": "2026-09-04T10:00:00Z"}, parent="900001",
                 rels={"preReleaseVersion": {"type": "preReleaseVersions", "id": other["id"]}})
        code, lines = self.apply(fake, ["--steps", "build"])
        self.assertEqual(code, 0)
        patch = self.writes(fake)[0]
        self.assertEqual(patch["body"]["data"]["id"], b8["id"])
        self.assertIn("SET build: attached build 8 to version 1.0", lines)
        fake2 = self.tool.fake(complete=False)
        older = fake2.all("builds")[0]
        fake2.add("builds", {"version": "8", "processingState": "VALID", "expired": False,
                             "uploadedDate": "2026-09-02T10:00:00Z"}, parent="900001",
                  rels={"preReleaseVersion": {"type": "preReleaseVersions", "id": fake2.all("preReleaseVersions")[0]["id"]}})
        code, lines = self.apply(fake2, ["--steps", "build", "--build-number", "7"])
        self.assertEqual(code, 0)
        self.assertEqual(self.writes(fake2)[0]["body"]["data"]["id"], older["id"])
        code, lines = self.apply(fake2, ["--steps", "build", "--build-number", "99"])
        self.assertEqual(code, 1)
        self.assertIn("FAIL build: no valid build number 99 exists for version 1.0", lines)

    def test_build_already_attached_and_no_build(self):
        fake = self.tool.fake()
        _c, lines = self.apply(fake, ["--steps", "build"])
        self.assertIn("SKIP build: build 7 is already attached", lines)
        self.assertEqual(self.writes(fake), [])
        fake = self.tool.fake(complete=False)
        fake.db["builds"].clear()
        code, lines = self.apply(fake, ["--steps", "build"])
        self.assertEqual(code, 0)
        self.assertTrue(any(l.startswith("SKIP build: no valid build exists for version 1.0") for l in lines))

    def test_failed_step_continues_and_exit_is_1(self):
        fake = self.tool.fake(complete=False)
        fake.failures.append(("PATCH", r"ageRatingDeclarations", 409, [
            {"code": "ENTITY_ERROR", "title": "Bad",
             "detail": "for %s and %s id 1234567890" % (FAKE_BUNDLE, CONTACT["REVIEW_CONTACT_EMAIL"])}]))
        code, lines = self.apply(fake)
        self.assertEqual(code, 1)
        fail = [l for l in lines if l.startswith("FAIL")]
        self.assertEqual(len(fail), 1)
        self.assertIn("HTTP 409", fail[0])
        blob = "\n".join(lines)
        for secret in (FAKE_BUNDLE, CONTACT["REVIEW_CONTACT_EMAIL"], "1234567890"):
            self.assertNotIn(secret, blob)
        self.assertTrue(any(e["path"] == "/v1/appPriceSchedules" for e in self.writes(fake)), "later steps still ran")
        self.assertTrue(lines[-1].startswith("RESULT: 1 step(s) failed"))

    def test_steps_flag(self):
        fake = self.tool.fake(complete=False)
        code, lines = self.apply(fake, ["--steps", "copyright,contentrights"])
        self.assertEqual(code, 0)
        self.assertEqual(sorted(e["path"] for e in self.writes(fake)),
                         sorted(["/v1/appStoreVersions/%s" % fake.all("appStoreVersions")[0]["id"], "/v1/apps/900001"]))
        self.assertIn("SKIP price: not selected with --steps", lines)
        code, lines = self.apply(fake, ["--steps", "nonsense"])
        self.assertEqual(code, 2)

    def test_invalid_listing_stops_before_any_request(self):
        path = self.listing_copy(name="n" * 31, keywords="k" * 101, description="d" * 4001)
        fake = self.tool.fake(complete=False)
        code, lines = self.apply(fake, listing=path)
        self.assertEqual(code, 1)
        self.assertEqual(fake.log, [])
        self.assertIn("ERROR listing: name: 31 characters, the limit is 30", lines)
        self.assertIn("ERROR listing: keywords: 101 characters, the limit is 100", lines)
        self.assertIn("ERROR listing: description: 4001 characters, the limit is 4000", lines)

    def test_missing_listing_stops(self):
        fake = self.tool.fake(complete=False)
        code, _lines = self.apply(fake, listing=os.path.join(HERE, "absent.json"))
        self.assertEqual(code, 1)
        self.assertEqual(fake.log, [])

    def test_never_deletes_and_never_submits(self):
        fake = self.tool.fake(complete=False)
        self.apply(fake)
        self.apply(fake)
        for entry in fake.log:
            self.assertNotEqual(entry["method"], "DELETE")
            self.assertNotRegex(entry["path"], r"(?i)submission|submit")

    def test_price_schedule_present_is_left_alone(self):
        fake = self.tool.fake()
        code, lines = self.apply(fake, ["--steps", "price"])
        self.assertEqual(code, 0)
        self.assertIn("SKIP price schedule: a price is already set", lines)
        self.assertEqual(self.writes(fake), [])

    def test_no_free_price_point_fails(self):
        fake = self.tool.fake(complete=False)
        del fake.db["appPricePoints"]["pp-free"]
        code, lines = self.apply(fake, ["--steps", "price"])
        self.assertEqual(code, 1)
        self.assertTrue(any(l.startswith("FAIL price schedule: no Free price point") for l in lines))

    def test_app_or_version_missing(self):
        fake = self.tool.fake(complete=False)
        fake.db["apps"].clear()
        code, lines = self.apply(fake)
        self.assertEqual(code, 1)
        self.assertTrue(any(l.startswith("FAIL app record") for l in lines))
        fake = self.tool.fake(complete=False)
        fake.all("appStoreVersions")[0]["attributes"]["appVersionState"] = "IN_REVIEW"
        code, _lines = self.apply(fake)
        self.assertEqual(code, 1)
        self.assertEqual(self.writes(fake), [])

    def test_rejected_credentials_exit_2(self):
        fake = self.tool.fake(complete=False)
        fake.public_key = new_key().public_key()
        code, _lines = self.apply(fake)
        self.assertEqual(code, 2)


def real_like(tool, locale="en-GB"):
    """What the first real run showed: primary locale en-GB, empty localisations, no build attached."""
    fake = tool.fake(complete=False, locale=locale)
    fake.add("appStoreVersionLocalizations", {"locale": locale}, parent=fake.all("appStoreVersions")[0]["id"])
    fake.add("appInfoLocalizations", {"locale": locale, "name": "Test App"}, parent=fake.all("appInfos")[0]["id"])
    return fake


def add_build(fake, marketing, number, uploaded, state="VALID"):
    pre = next((p for p in fake.all("preReleaseVersions") if p["attributes"]["version"] == marketing), None)
    if pre is None:
        pre = fake.add("preReleaseVersions", {"version": marketing}, parent="900001")
    return fake.add("builds", {"version": str(number), "processingState": state, "expired": False,
                               "uploadedDate": uploaded, "usesNonExemptEncryption": False},
                    parent="900001", rels={"preReleaseVersion": {"type": "preReleaseVersions", "id": pre["id"]}})


class RealRunTests(unittest.TestCase):
    """Each test reproduces one finding of the first real run against the fake API."""

    def setUp(self):
        self.tool = ToolRun(CONTACT)
        self.addCleanup(self.tool.close)

    def check(self, fake, extra=None):
        return self.tool.run(fake, ["check", "--listing", LISTING_PATH] + (extra or []))

    def apply(self, fake, extra=None):
        return self.tool.run(fake, ["apply", "--listing", LISTING_PATH] + (extra or []))

    @staticmethod
    def writes(fake):
        return [e for e in fake.log if e["method"] != "GET"]

    # 1 locale
    def test_check_targets_the_primary_locale(self):
        fake = real_like(self.tool)
        _c, lines = self.check(fake)
        self.assertIn("INFO target locale: en-GB (the app's primary locale)", lines)
        self.assertIn("INFO listing text: written from listing locale en-US to en-GB", lines)
        self.assertTrue(any(l.startswith("MISSING version localisation en-GB description") for l in lines))
        self.assertTrue(any(l.startswith("MISSING app info localisation en-GB privacy policy URL") for l in lines))
        self.assertFalse(any("en-US" in l and "listing" not in l for l in lines), "\n".join(lines))

    def test_apply_updates_the_existing_primary_locale_localisations(self):
        fake = real_like(self.tool)
        code, lines = self.apply(fake, ["--steps", "localisation,appinfo"])
        self.assertEqual(code, 0, "\n".join(lines))
        self.assertIn("INFO target locale: en-GB (the app's primary locale)", lines)
        writes = self.writes(fake)
        self.assertEqual([e["method"] for e in writes[:2]], ["PATCH", "PATCH"])
        self.assertTrue(writes[0]["path"].startswith("/v1/appStoreVersionLocalizations/"))
        self.assertNotIn("locale", writes[0]["body"]["data"]["attributes"])
        self.assertEqual(writes[0]["body"]["data"]["attributes"]["keywords"], "test,placeholder,example")
        self.assertTrue(writes[1]["path"].startswith("/v1/appInfoLocalizations/"))
        self.assertEqual(fake.requests("POST", r"Localizations$"), [])
        self.assertEqual(len(fake.all("appStoreVersionLocalizations")), 1)

    def test_locale_override(self):
        fake = real_like(self.tool)
        code, lines = self.apply(fake, ["--steps", "localisation", "--locale", "de-DE"])
        self.assertEqual(code, 0)
        self.assertIn("INFO target locale: de-DE (from --locale)", lines)
        posts = fake.requests("POST", r"^/v1/appStoreVersionLocalizations$")
        self.assertEqual(posts[0]["body"]["data"]["attributes"]["locale"], "de-DE")
        code, _l = self.apply(fake, ["--locale", "English"])
        self.assertEqual(code, 2)

    def test_locale_falls_back_to_the_listing_when_the_app_has_none(self):
        fake = real_like(self.tool, locale="en-US")
        del fake.all("apps")[0]["attributes"]["primaryLocale"]
        _c, lines = self.check(fake)
        self.assertIn("INFO target locale: en-US (from the listing, because the app reports no primary locale)", lines)

    def test_screenshots_use_the_target_locale(self):
        fake = real_like(self.tool)
        _c, lines = self.check(fake)
        self.assertTrue(any(l.startswith("MISSING screenshots en-GB iPhone 6.9 inch") for l in lines))

    # 2 build read
    def test_attached_build_is_read_without_include(self):
        fake = real_like(self.tool)
        fake.all("appStoreVersions")[0]["rels"]["build"] = {"type": "builds", "id": fake.all("builds")[0]["id"]}
        _c, lines = self.check(fake)
        for e in fake.requests("GET", r"/build$"):
            self.assertNotIn("include", e["query"])
        self.assertIn("PASS build attached: build 7, version 1.0, processing VALID", lines)
        self.assertFalse(any("could not be read" in l for l in lines), "\n".join(lines))

    def test_no_build_attached_is_a_missing_line_not_an_error(self):
        fake = real_like(self.tool)
        _c, lines = self.check(fake)
        self.assertTrue(any(l.startswith("MISSING build attached: no build is attached") for l in lines))

    def test_build_read_404_counts_as_none(self):
        fake = real_like(self.tool)
        fake.failures.append(("GET", r"/build$", 404, [{"code": "NOT_FOUND", "title": "x"}]))
        _c, lines = self.check(fake)
        self.assertTrue(any(l.startswith("MISSING build attached: no build is attached") for l in lines))

    # 3 price
    def test_price_stub_reads_as_not_set(self):
        fake = real_like(self.tool)
        _c, lines = self.check(fake)
        self.assertTrue(any(l.startswith("MISSING price schedule: not set, run apply") or
                            l.startswith("MISSING price schedule: not set: run apply") for l in lines), "\n".join(lines))
        self.assertFalse(any("price schedule prices" in l for l in lines))
        self.assertFalse(any("could not be read" in l for l in lines), "\n".join(lines))

    def test_price_apply_sets_free_once(self):
        fake = real_like(self.tool)
        code, lines = self.apply(fake, ["--steps", "price"])
        self.assertEqual(code, 0, "\n".join(lines))
        self.assertIn("SET price schedule: Free set for the base territory", lines)
        self.assertEqual(len(fake.requests("POST", r"^/v1/appPriceSchedules$")), 1)
        code, lines = self.apply(fake, ["--steps", "price"])
        self.assertIn("SKIP price schedule: a price is already set", lines)
        self.assertEqual(len(fake.requests("POST", r"^/v1/appPriceSchedules$")), 1)
        _c, chk = self.check(fake)
        self.assertIn("PASS price schedule: set, Free", chk)

    def test_price_base_territory_flag(self):
        fake = real_like(self.tool)
        fake.add("appPricePoints", {"customerPrice": "0.0"}, parent="IRL", rid="pp-irl-free")
        code, _l = self.apply(fake, ["--steps", "price", "--base-territory", "IRL"])
        self.assertEqual(code, 0)
        body = fake.requests("POST", r"appPriceSchedules$")[0]["body"]
        self.assertEqual(body["data"]["relationships"]["baseTerritory"]["data"]["id"], "IRL")
        self.assertEqual(body["included"][0]["relationships"]["appPricePoint"]["data"]["id"], "pp-irl-free")

    # 4 version string
    def two_versions(self):
        fake = real_like(self.tool)
        fake.db["builds"].clear()
        add_build(fake, "1.0", 1, "2026-09-01T10:00:00Z")
        add_build(fake, "0.1.5", 12, "2026-09-20T10:00:00Z")
        return fake

    def test_check_reports_a_version_mismatch(self):
        fake = self.two_versions()
        _c, lines = self.check(fake)
        line = next(l for l in lines if l.startswith("MISSING version string"))
        self.assertIn("the editable version is 1.0 but the newest valid build (build 12) is for 0.1.5", line)
        self.assertIn("apply sets the version to 0.1.5 and attaches that build", line)
        self.assertIn("--set-version keep", line)

    def test_apply_sets_the_version_and_attaches_the_newest_valid_build(self):
        fake = self.two_versions()
        vid = fake.all("appStoreVersions")[0]["id"]
        newest = next(b for b in fake.all("builds") if b["attributes"]["version"] == "12")
        code, lines = self.apply(fake, ["--steps", "version,build"])
        self.assertEqual(code, 0, "\n".join(lines))
        self.assertIn("SET version: changed the version from 1.0 to 0.1.5 (from build 12)", lines)
        self.assertIn("SET build: attached build 12 to version 0.1.5", lines)
        writes = self.writes(fake)
        self.assertEqual([(e["method"], e["path"]) for e in writes], [
            ("PATCH", "/v1/appStoreVersions/%s" % vid),
            ("PATCH", "/v1/appStoreVersions/%s/relationships/build" % vid)])
        self.assertEqual(writes[0]["body"]["data"]["attributes"], {"versionString": "0.1.5"})
        self.assertEqual(writes[1]["body"]["data"]["id"], newest["id"])
        self.assertEqual(fake.all("appStoreVersions")[0]["attributes"]["versionString"], "0.1.5")
        _c, chk = self.check(fake)
        self.assertIn("PASS version string: 0.1.5 matches the newest valid build (build 12)", chk)
        code, lines = self.apply(fake, ["--steps", "version,build"])
        self.assertEqual(len(self.writes(fake)), 2, "the second run must not write")
        self.assertIn("SKIP version: already 0.1.5", lines)

    def test_set_version_keep_and_explicit(self):
        fake = self.two_versions()
        code, lines = self.apply(fake, ["--steps", "version,build", "--set-version", "keep"])
        self.assertEqual(code, 0)
        self.assertIn("SKIP version: kept at 1.0", lines)
        self.assertIn("SET build: attached build 1 to version 1.0", lines)
        fake = self.two_versions()
        code, lines = self.apply(fake, ["--steps", "version,build", "--set-version", "0.1.5"])
        self.assertIn("SET version: changed the version from 1.0 to 0.1.5 (from --set-version)", lines)
        self.assertIn("SET build: attached build 12 to version 0.1.5", lines)

    def test_build_version_and_build_number_choose_the_build(self):
        fake = self.two_versions()
        code, lines = self.apply(fake, ["--steps", "version,build", "--build-version", "1.0"])
        self.assertEqual(code, 0)
        self.assertIn("SKIP version: already 1.0", lines)
        self.assertIn("SET build: attached build 1 to version 1.0", lines)
        fake = self.two_versions()
        add_build(fake, "0.1.5", 13, "2026-09-21T10:00:00Z")
        code, lines = self.apply(fake, ["--steps", "version,build", "--build-number", "12"])
        self.assertIn("SET build: attached build 12 to version 0.1.5", lines)

    def test_processing_build_is_never_chosen_for_the_version(self):
        fake = self.two_versions()
        add_build(fake, "0.2.0", 20, "2026-09-25T10:00:00Z", state="PROCESSING")
        _c, lines = self.apply(fake, ["--steps", "version"])
        self.assertIn("SET version: changed the version from 1.0 to 0.1.5 (from build 12)", lines)

    def test_version_is_refused_when_not_editable(self):
        fake = self.two_versions()
        fake.all("appStoreVersions")[0]["attributes"]["appVersionState"] = "WAITING_FOR_REVIEW"
        code, lines = self.apply(fake, ["--steps", "version", "--set-version", "0.1.5"])
        self.assertEqual(code, 1)
        self.assertEqual(self.writes(fake), [])
        self.assertIn("FAIL editable version: no version can be edited: create a new version in App Store Connect", lines)

    def test_version_step_refuses_a_state_the_api_would_reject(self):
        fake = self.two_versions()
        fake.all("appStoreVersions")[0]["attributes"]["appVersionState"] = "INVALID_BINARY"
        code, lines = self.apply(fake, ["--steps", "version", "--set-version", "0.1.5"])
        self.assertEqual(code, 1)
        self.assertTrue(any(l.startswith("FAIL version: HTTP 409") for l in lines))

    def test_bad_version_arguments(self):
        fake = self.two_versions()
        for extra in (["--set-version", "1.x"], ["--build-version", "abc"], ["--territories", "usa"]):
            code, lines = self.apply(fake, extra)
            self.assertEqual(code, 2, extra)
        self.assertEqual(fake.log, [])

    # 5 availability
    def test_availability_is_set_for_all_territories(self):
        fake = real_like(self.tool)
        code, lines = self.apply(fake, ["--steps", "availability"])
        self.assertEqual(code, 0, "\n".join(lines))
        self.assertIn("SET availability: set for 5 territories, new territories included", lines)
        post = fake.requests("POST", r"^/v2/appAvailabilities$")[0]["body"]
        self.assertEqual(post["data"]["type"], "appAvailabilities")
        self.assertEqual(post["data"]["attributes"], {"availableInNewTerritories": True})
        self.assertEqual(post["data"]["relationships"]["app"]["data"], {"type": "apps", "id": "900001"})
        refs = [r["id"] for r in post["data"]["relationships"]["territoryAvailabilities"]["data"]]
        self.assertEqual(sorted(refs), sorted(i["id"] for i in post["included"]))
        self.assertEqual(sorted(i["relationships"]["territory"]["data"]["id"] for i in post["included"]),
                         ["DEU", "FRA", "GBR", "IRL", "USA"])
        self.assertTrue(all(i["attributes"] == {"available": True} for i in post["included"]))
        _c, chk = self.check(fake)
        self.assertIn("PASS availability: 5 territories", chk)
        code, lines = self.apply(fake, ["--steps", "availability"])
        self.assertIn("SKIP availability: already set for 5 territories", lines)
        self.assertEqual(len(fake.requests("POST", r"appAvailabilities")), 1)

    def test_availability_list_and_unknown_code(self):
        fake = real_like(self.tool)
        code, lines = self.apply(fake, ["--steps", "availability", "--territories", "USA,IRL"])
        self.assertEqual(code, 0)
        self.assertIn("SET availability: set for 2 territories", lines)
        post = fake.requests("POST", r"appAvailabilities")[0]["body"]
        self.assertEqual(post["data"]["attributes"], {"availableInNewTerritories": False})
        fake = real_like(self.tool)
        code, lines = self.apply(fake, ["--steps", "availability", "--territories", "USA,ZZZ"])
        self.assertEqual(code, 1)
        self.assertIn("FAIL availability: 1 unknown territory code(s) in --territories", lines)
        self.assertEqual(self.writes(fake), [])

    # 6 the whole picture
    def test_fresh_check_has_no_unreadable_lines_and_only_settable_or_manual_gaps(self):
        fake = real_like(self.tool)
        _c, lines = self.check(fake)
        self.assertFalse(any("could not be read" in l for l in lines), "\n".join(lines))

    def test_apply_then_check_leaves_only_screenshots_and_manual_items(self):
        fake = self.two_versions()
        code, lines = self.apply(fake)
        self.assertEqual(code, 0, "\n".join(lines))
        _c, chk = self.check(fake)
        missing = sorted(l.split(":")[0] for l in chk if l.startswith("MISSING"))
        self.assertEqual(missing, ["MISSING screenshots en-GB iPad 13 inch", "MISSING screenshots en-GB iPhone 6.9 inch"],
                         "\n".join(chk))
        self.assertFalse(any("could not be read" in l for l in chk))
        self.assertEqual(len([l for l in chk if l.startswith("MANUAL")]), 3)


class ScreenshotTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.iphone = fake_asc.make_png(1290, 2796)
        cls.iphone_b = fake_asc.make_png(1320, 2868)
        cls.ipad = fake_asc.make_png(2064, 2752)

    def setUp(self):
        self.tool = ToolRun(CONTACT)
        self.addCleanup(self.tool.close)
        self.shots = os.path.join(self.tool.tmp.name, "shots")

    def put(self, folder, name, data):
        path = os.path.join(self.shots, folder)
        os.makedirs(path, exist_ok=True)
        with open(os.path.join(path, name), "wb") as fh:
            fh.write(data)

    def run_apply(self, fake, extra=None, steps="localisation,screenshots"):
        argv = ["apply", "--listing", LISTING_PATH, "--steps", steps, "--screenshots-dir", self.shots]
        return self.tool.run(fake, argv + (extra or []))

    def test_three_step_upload_with_checksum_and_order(self):
        fake = self.tool.fake(complete=False)
        self.put("APP_IPHONE_67", "01.png", self.iphone)
        self.put("APP_IPHONE_67", "02.png", self.iphone_b)
        self.put("APP_IPHONE_67", "10.png", self.iphone)
        self.put("APP_IPAD_PRO_3GEN_129", "01.png", self.ipad)
        code, lines = self.run_apply(fake)
        self.assertEqual(code, 0, "\n".join(lines))
        self.assertIn("SET screenshots APP_IPHONE_67: uploaded 3 screenshot(s) in order", lines)
        self.assertIn("SET screenshots APP_IPAD_PRO_3GEN_129: uploaded 1 screenshot(s) in order", lines)
        posts = fake.requests("POST", r"^/v1/appScreenshots$")
        self.assertEqual([p["body"]["data"]["attributes"]["fileName"] for p in posts],
                         ["01.png", "01.png", "02.png", "10.png"])
        self.assertEqual(posts[0]["body"]["data"]["attributes"]["fileSize"], len(self.ipad))
        rel = posts[0]["body"]["data"]["relationships"]["appScreenshotSet"]["data"]
        self.assertEqual(rel["type"], "appScreenshotSets")
        # Step 2: the parts arrived, none carried API credentials, and they add up to the file.
        expected_parts = sum(-(-len(x) // 5000) for x in (self.iphone, self.iphone_b, self.iphone, self.ipad))
        self.assertEqual(len(fake.upload_requests), expected_parts)
        self.assertGreater(expected_parts, 4)
        for _m, _p, headers, _n in fake.upload_requests:
            self.assertNotIn("Authorization", headers)
            self.assertEqual(headers["Content-Type"], "image/png")
        blobs = list(fake.uploaded.values())
        self.assertEqual(blobs, [self.ipad, self.iphone, self.iphone_b, self.iphone])
        # Step 3: commit with the md5 checksum, then poll to COMPLETE.
        import hashlib
        commits = fake.requests("PATCH", r"^/v1/appScreenshots/")
        self.assertEqual(len(commits), 4)
        self.assertEqual(commits[0]["body"]["data"]["attributes"],
                         {"uploaded": True, "sourceFileChecksum": hashlib.md5(self.ipad).hexdigest()})
        self.assertEqual(commits[2]["body"]["data"]["attributes"]["sourceFileChecksum"],
                         hashlib.md5(self.iphone_b).hexdigest())
        self.assertGreaterEqual(len(fake.requests("GET", r"^/v1/appScreenshots/")), 4 * 2)
        for shot in fake.all("appScreenshots"):
            self.assertEqual(shot["attributes"]["assetDeliveryState"]["state"], "COMPLETE")
        # Ordering follows the natural file order.
        order_calls = fake.requests("PATCH", r"/relationships/appScreenshots$")
        self.assertEqual(len(order_calls), 1)
        self.assertEqual(len(order_calls[0]["body"]["data"]), 3)
        self.assertEqual(order_calls[0]["body"]["data"][0]["type"], "appScreenshots")
        set_body = fake.requests("POST", r"^/v1/appScreenshotSets$")[1]["body"]["data"]
        self.assertEqual(set_body["attributes"], {"screenshotDisplayType": "APP_IPHONE_67"})
        self.assertEqual(set_body["relationships"]["appStoreVersionLocalization"]["data"]["type"],
                         "appStoreVersionLocalizations")
        # Order of calls for the first file: reserve, parts, commit.
        first = [(e["method"], e["path"]) for e in fake.log if "appScreenshots" in e["path"]][:3]
        self.assertEqual(first[0], ("POST", "/v1/appScreenshots"))
        self.assertEqual(first[1][0], "PATCH")

    def test_upload_then_check_passes(self):
        fake = self.tool.fake(complete=False)
        self.put("APP_IPHONE_67", "01.png", self.iphone)
        self.put("APP_IPAD_PRO_3GEN_129", "01.png", self.ipad)
        self.assertEqual(self.run_apply(fake)[0], 0)
        _c, lines = self.tool.run(fake, ["check", "--listing", LISTING_PATH])
        self.assertTrue(any(l.startswith("PASS screenshots en-US iPhone 6.9 inch: 1 in APP_IPHONE_67") for l in lines))
        self.assertTrue(any(l.startswith("PASS screenshots en-US iPad 13 inch: 1 in APP_IPAD_PRO_3GEN_129") for l in lines))

    def test_existing_set_is_skipped_unless_replace(self):
        fake = self.tool.fake()
        self.put("APP_IPHONE_67", "01.png", self.iphone)
        code, lines = self.run_apply(fake, steps="screenshots")
        self.assertEqual(code, 0)
        self.assertTrue(any(l.startswith("SKIP screenshots APP_IPHONE_67: 2 screenshot(s) already uploaded") for l in lines))
        self.assertEqual([e for e in fake.log if e["method"] != "GET"], [])
        code, lines = self.run_apply(fake, ["--replace-screenshots"], steps="screenshots")
        self.assertEqual(code, 0, "\n".join(lines))
        self.assertIn("SET screenshots APP_IPHONE_67: removed 2 screenshot(s) for replacement", lines)
        self.assertEqual(len(fake.requests("DELETE")), 2)
        sets = fake.all("appScreenshotSets")
        iphone = next(s for s in sets if s["attributes"]["screenshotDisplayType"] == "APP_IPHONE_67")
        self.assertEqual(len(fake.all("appScreenshots", iphone["id"])), 1)
        self.assertEqual(len(fake.all("appScreenshots", next(s for s in sets if s is not iphone)["id"])), 2,
                         "the other display type must not be touched")

    def test_wrong_size_is_rejected_before_any_write(self):
        fake = self.tool.fake(complete=False)
        self.put("APP_IPHONE_67", "01.png", fake_asc.make_png(1000, 1000))
        self.put("APP_IPAD_PRO_3GEN_129", "01.png", self.ipad)
        code, lines = self.run_apply(fake)
        self.assertEqual(code, 1)
        self.assertIn("FAIL screenshots APP_IPHONE_67: file 1 is 1000x1000 pixels, which APP_IPHONE_67 does not accept", lines)
        types = [s["attributes"]["screenshotDisplayType"] for s in fake.all("appScreenshotSets")]
        self.assertEqual(types, ["APP_IPAD_PRO_3GEN_129"])

    def test_folder_and_file_problems(self):
        fake = self.tool.fake(complete=False)
        self.put("APP_IPHONE_99", "01.png", self.iphone)
        self.put("APP_IPHONE_67", "01.png", b"not a png at all, just text")
        for i in range(11):
            self.put("APP_IPAD_PRO_3GEN_129", "%02d.png" % i, b"x")
        code, lines = self.run_apply(fake)
        self.assertEqual(code, 1)
        self.assertIn("FAIL screenshots APP_IPHONE_99: the folder name is not a known display type", lines)
        self.assertIn("FAIL screenshots APP_IPHONE_67: file 1 is not a PNG", lines)
        self.assertIn("FAIL screenshots APP_IPAD_PRO_3GEN_129: 11 files, the maximum is 10", lines)
        self.assertEqual(fake.all("appScreenshotSets"), [])

    def test_alpha_channel_is_reported_not_blocked(self):
        fake = self.tool.fake(complete=False)
        self.put("APP_IPHONE_67", "01.png", fake_asc.make_png(1290, 2796, alpha=True))
        code, lines = self.run_apply(fake)
        self.assertEqual(code, 0)
        self.assertIn("INFO screenshots APP_IPHONE_67: file 1 has an alpha channel, Apple can reject that", lines)

    def test_checksum_failure_reported(self):
        fake = self.tool.fake(complete=False)
        fake.corrupt = True
        self.put("APP_IPHONE_67", "01.png", self.iphone)
        code, lines = self.run_apply(fake)
        self.assertEqual(code, 1)
        self.assertTrue(any(l.startswith("FAIL screenshots APP_IPHONE_67: file 1: Apple could not process the upload (CHECKSUM)") for l in lines))

    def test_poll_timeout(self):
        fake = self.tool.fake(complete=False, upload_polls=10 ** 6)
        self.put("APP_IPHONE_67", "01.png", self.iphone)
        code, lines = self.run_apply(fake)
        self.assertEqual(code, 1)
        self.assertTrue(any("did not reach COMPLETE within 180 seconds" in l for l in lines))

    def test_upload_host_error_reported(self):
        fake = self.tool.fake(complete=False)
        self.put("APP_IPHONE_67", "01.png", self.iphone)
        original = fake.handle_upload

        def refuse(method, path, headers, body):
            return 403, {}, b"denied"
        fake.handle_upload = refuse
        code, lines = self.run_apply(fake)
        fake.handle_upload = original
        self.assertEqual(code, 1)
        self.assertTrue(any(l.startswith("FAIL screenshots APP_IPHONE_67: HTTP 403") for l in lines))

    def test_missing_localisation_and_no_dir(self):
        fake = self.tool.fake(complete=False)
        self.put("APP_IPHONE_67", "01.png", self.iphone)
        code, lines = self.run_apply(fake, steps="screenshots")
        self.assertEqual(code, 1)
        self.assertTrue(any("run the localisation step first" in l for l in lines))
        code, lines = self.tool.run(self.tool.fake(complete=False),
                                    ["apply", "--listing", LISTING_PATH, "--steps", "screenshots"])
        self.assertEqual(code, 0)
        self.assertIn("SKIP screenshots: no --screenshots-dir was given", lines)
        code, _l = self.tool.run(self.tool.fake(complete=False),
                                 ["apply", "--listing", LISTING_PATH, "--screenshots-dir", os.path.join(self.shots, "nope")])
        self.assertEqual(code, 2)

    def test_file_names_and_ids_not_in_output(self):
        fake = self.tool.fake(complete=False)
        self.put("APP_IPHONE_67", "secretname-01.png", self.iphone)
        _c, lines = self.run_apply(fake)
        self.assertNotIn("secretname", "\n".join(lines))

    def test_png_helpers(self):
        self.assertEqual(t.png_info(self.iphone), (1290, 2796, False))
        self.assertEqual(t.png_info(fake_asc.make_png(10, 20, alpha=True)), (10, 20, True))
        self.assertIsNone(t.png_info(b"GIF89a" + b"0" * 60))
        self.assertEqual(sorted(["10.png", "2.png", "01.png"], key=t.natural_key), ["01.png", "2.png", "10.png"])
        self.assertIn((1290, 2796), t.DISPLAY_SIZES["APP_IPHONE_67"])
        self.assertIn((2752, 2064), t.DISPLAY_SIZES["APP_IPAD_PRO_3GEN_129"])


class ListingTests(unittest.TestCase):
    def load(self):
        with open(LISTING_PATH, encoding="utf-8") as fh:
            return json.load(fh)

    def test_fixture_is_valid_and_has_the_agreed_keys(self):
        doc = self.load()
        self.assertEqual(t.validate_listing(doc), [])
        self.assertEqual(set(doc), set(t.LISTING_KEYS))

    def test_limits_rejected(self):
        for key, limit in t.LIMITS.items():
            doc = self.load()
            doc[key] = "x" * (limit + 1)
            problems = t.validate_listing(doc)
            self.assertEqual(len(problems), 1, key)
            self.assertIn("%s: %d characters, the limit is %d" % (key, limit + 1, limit), problems[0])
            doc[key] = "x" * limit
            self.assertEqual(t.validate_listing(doc), [], key)

    def test_missing_key_and_bad_types(self):
        doc = self.load()
        del doc["copyright"]
        doc["reviewDemoRequired"] = "no"
        doc["supportUrl"] = "not a url"
        doc["contentRightsDeclaration"] = "MAYBE"
        doc["ageRating"] = {"advertising": 3}
        doc["locale"] = "English"
        joined = " | ".join(t.validate_listing(doc))
        for word in ("copyright: key is missing", "reviewDemoRequired", "supportUrl", "contentRightsDeclaration",
                     "ageRating.advertising", "locale"):
            self.assertIn(word, joined)

    def test_load_listing(self):
        doc, problems = t.load_listing(LISTING_PATH)
        self.assertEqual(problems, [])
        self.assertEqual(doc["locale"], "en-US")
        self.assertEqual(t.load_listing(os.path.join(HERE, "nope.json")), (None, []))


if __name__ == "__main__":
    unittest.main()
