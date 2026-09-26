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
FAKE_KEY_ID = "K" + "EY" + "FAKE" + "0001"
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


if __name__ == "__main__":
    unittest.main()
