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
        self.assertIn("MISSING build attached: the attached build is for version 0.9 but the editable version is 1.0: run apply", lines)
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
