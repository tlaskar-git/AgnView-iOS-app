#!/usr/bin/env python3
"""A small in-memory fake of the App Store Connect API for asc_tool tests.

It is a transport function: fake(method, url, headers, body, timeout) returns
(status, headers, body). It also plays the upload host for screenshot parts.
It records every request in .log and enforces a few real API rules so the tool
is tested against realistic answers. Fake values only.
"""
import base64
import hashlib
import json
import re
import struct
import zlib
from urllib.parse import parse_qs, urlsplit

UPLOAD_HOST = "upload.example.test"
API_HOST = "api.appstoreconnect.apple.com"


def make_png(width, height, alpha=False):
    """A valid solid PNG of the given size. RGB by default, RGBA when alpha is True."""
    channels, colour_type = (4, 6) if alpha else (3, 2)
    row = b"\x00" + bytes([40, 90, 160, 255][:channels]) * width
    comp = zlib.compressobj(9)
    parts = [comp.compress(row) for _ in range(height)]
    parts.append(comp.flush())
    idat = b"".join(parts)

    def chunk(tag, data):
        body = tag + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, colour_type, 0, 0, 0))
            + chunk(b"IDAT", idat) + chunk(b"IEND", b""))


class FakeAsc:
    def __init__(self, bundle_id, public_key=None, part_size=5000, upload_polls=2):
        self.bundle_id = bundle_id
        self.public_key = public_key
        self.part_size = part_size
        self.upload_polls = upload_polls
        self.db = {}
        self.log = []
        self.failures = []  # (method, path regex, status, errors)
        self.parts = {}  # shot id -> {index: bytes}
        self.uploaded = {}  # shot id -> assembled bytes
        self.polls = {}
        self.order = {}
        self.upload_requests = []
        self.first_version_rejects_whats_new = True
        self.corrupt = False
        self.price_stub = True
        self.counter = 0

    # ------------------------------------------------------------ storage
    def new_id(self, prefix):
        self.counter += 1
        return "%s-%d" % (prefix, self.counter)

    def add(self, rtype, attributes=None, parent=None, rid=None, rels=None):
        rid = rid or self.new_id(rtype)
        res = {"type": rtype, "id": rid, "attributes": dict(attributes or {}),
               "rels": dict(rels or {}), "parent": parent}
        self.db.setdefault(rtype, {})[rid] = res
        return res

    def all(self, rtype, parent=None):
        return [r for r in self.db.get(rtype, {}).values() if parent is None or r["parent"] == parent]

    def one(self, rtype, rid):
        return self.db.get(rtype, {}).get(rid)

    def ser(self, res):
        out = {"type": res["type"], "id": res["id"], "attributes": res["attributes"]}
        if res["rels"]:
            out["relationships"] = {k: {"data": v} for k, v in res["rels"].items()}
        return out

    def requests(self, method=None, pattern=None):
        return [e for e in self.log
                if (method is None or e["method"] == method)
                and (pattern is None or re.search(pattern, e["path"]))]

    # ------------------------------------------------------- transport
    def __call__(self, method, url, headers, body, timeout):
        parts = urlsplit(url)
        if parts.hostname == UPLOAD_HOST:
            return self.handle_upload(method, parts.path, headers, body)
        if parts.hostname != API_HOST:
            return 404, {}, b""
        auth = headers.get("Authorization", "")
        if not auth.startswith("Bearer ") or not self.token_ok(auth[7:]):
            return self.err(401, "NOT_AUTHORIZED", "Authentication credentials are missing or invalid.")
        query = {k: v[0] for k, v in parse_qs(parts.query).items()}
        doc = json.loads(body.decode()) if body else None
        entry = {"method": method, "path": parts.path, "query": query, "body": doc}
        self.log.append(entry)
        for fmethod, pattern, status, errors in self.failures:
            if fmethod == method and re.search(pattern, parts.path):
                return status, {}, json.dumps({"errors": errors}).encode()
        return self.route(method, parts.path, query, doc)

    def token_ok(self, token):
        if self.public_key is None:
            return True
        from cryptography.hazmat.primitives import hashes
        from cryptography.hazmat.primitives.asymmetric import ec
        from cryptography.hazmat.primitives.asymmetric.utils import encode_dss_signature
        try:
            head, claims, sig = token.split(".")
            raw = base64.urlsafe_b64decode(sig + "=" * (-len(sig) % 4))
            der = encode_dss_signature(int.from_bytes(raw[:32], "big"), int.from_bytes(raw[32:], "big"))
            self.public_key.verify(der, (head + "." + claims).encode(), ec.ECDSA(hashes.SHA256()))
            return True
        except Exception:
            return False

    @staticmethod
    def reply(doc, status=200):
        return status, {}, json.dumps(doc).encode()

    @staticmethod
    def err(status, code, detail, title="Error"):
        return status, {}, json.dumps({"errors": [{"status": str(status), "code": code,
                                                   "title": title, "detail": detail}]}).encode()

    def listing(self, resources, included=None):
        doc = {"data": [self.ser(r) for r in resources], "links": {}}
        if included:
            doc["included"] = included
        return self.reply(doc)

    def single(self, res, included=None):
        doc = {"data": self.ser(res) if res else None}
        if included:
            doc["included"] = included
        return self.reply(doc)

    # ------------------------------------------------------------ routes
    def route(self, method, path, q, doc):
        m = re.fullmatch
        if method == "GET" and path == "/v1/apps":
            want = q.get("filter[bundleId]")
            return self.listing([a for a in self.all("apps") if a["attributes"]["bundleId"] == want])
        g = m(r"/v1/apps/([^/]+)", path)
        if g and method == "PATCH":
            return self.patch_attrs("apps", g.group(1), doc)
        g = m(r"/v1/apps/([^/]+)/appStoreVersions", path)
        if g and method == "GET":
            return self.listing(self.all("appStoreVersions", g.group(1)))
        g = m(r"/v1/appStoreVersions/([^/]+)", path)
        if g and method == "PATCH":
            return self.patch_attrs("appStoreVersions", g.group(1), doc)
        g = m(r"/v1/appStoreVersions/([^/]+)/build", path)
        if g and method == "GET":
            if "include" in q:
                return self.err(400, "PARAMETER_ERROR.ILLEGAL",
                                "The parameter 'include' can not be used with this request",
                                "A given parameter is not allowed for this request")
            version = self.one("appStoreVersions", g.group(1))
            ref = version["rels"].get("build")
            build = self.one("builds", ref["id"]) if ref else None
            return self.single(build)
        g = m(r"/v1/appStoreVersions/([^/]+)/relationships/build", path)
        if g and method == "PATCH":
            version = self.one("appStoreVersions", g.group(1))
            version["rels"]["build"] = doc["data"]
            return 204, {}, b""
        if method == "GET" and path == "/v1/builds":
            app_id = q.get("filter[app]")
            want = q.get("filter[preReleaseVersion.version]")
            found = []
            for b in self.all("builds", app_id):
                pre = self.one("preReleaseVersions", b["rels"]["preReleaseVersion"]["id"])
                if want is None or pre["attributes"]["version"] == want:
                    found.append(b)
            found.sort(key=lambda b: b["attributes"].get("uploadedDate", ""), reverse=True)
            if "preReleaseVersion" in q.get("include", ""):
                incl = {b["rels"]["preReleaseVersion"]["id"] for b in found}
                return self.listing(found, [self.ser(self.one("preReleaseVersions", i)) for i in sorted(incl)])
            return self.listing(found)
        g = m(r"/v1/appStoreVersions/([^/]+)/appStoreVersionLocalizations", path)
        if g and method == "GET":
            return self.listing(self.all("appStoreVersionLocalizations", g.group(1)))
        if method == "POST" and path == "/v1/appStoreVersionLocalizations":
            return self.create_localisation("appStoreVersionLocalizations", "appStoreVersion", doc)
        g = m(r"/v1/appStoreVersionLocalizations/([^/]+)", path)
        if g and method == "PATCH":
            return self.patch_attrs("appStoreVersionLocalizations", g.group(1), doc)
        g = m(r"/v1/apps/([^/]+)/appInfos", path)
        if g and method == "GET":
            infos = self.all("appInfos", g.group(1))
            included = []
            for info in infos:
                for name in ("primaryCategory", "secondaryCategory"):
                    ref = info["rels"].get(name)
                    if ref:
                        included.append({"type": "appCategories", "id": ref["id"], "attributes": {}})
            return self.listing(infos, included)
        g = m(r"/v1/appInfos/([^/]+)", path)
        if g and method == "PATCH":
            info = self.one("appInfos", g.group(1))
            for name, val in ((doc["data"].get("relationships") or {})).items():
                info["rels"][name] = val["data"]
            return self.single(info)
        g = m(r"/v1/appInfos/([^/]+)/appInfoLocalizations", path)
        if g and method == "GET":
            return self.listing(self.all("appInfoLocalizations", g.group(1)))
        if method == "POST" and path == "/v1/appInfoLocalizations":
            return self.create_localisation("appInfoLocalizations", "appInfo", doc)
        g = m(r"/v1/appInfoLocalizations/([^/]+)", path)
        if g and method == "PATCH":
            return self.patch_attrs("appInfoLocalizations", g.group(1), doc)
        g = m(r"/v1/appInfos/([^/]+)/ageRatingDeclaration", path)
        if g and method == "GET":
            found = self.all("ageRatingDeclarations", g.group(1))
            return self.single(found[0] if found else None)
        g = m(r"/v1/ageRatingDeclarations/([^/]+)", path)
        if g and method == "PATCH":
            return self.patch_attrs("ageRatingDeclarations", g.group(1), doc)
        g = m(r"/v1/appStoreVersions/([^/]+)/appStoreReviewDetail", path)
        if g and method == "GET":
            found = self.all("appStoreReviewDetails", g.group(1))
            return self.single(found[0] if found else None)
        if method == "POST" and path == "/v1/appStoreReviewDetails":
            vid = doc["data"]["relationships"]["appStoreVersion"]["data"]["id"]
            res = self.add("appStoreReviewDetails", doc["data"].get("attributes"), parent=vid)
            return self.reply({"data": self.ser(res)}, 201)
        g = m(r"/v1/appStoreReviewDetails/([^/]+)", path)
        if g and method == "PATCH":
            return self.patch_attrs("appStoreReviewDetails", g.group(1), doc)
        return self.route_screens_and_prices(method, path, q, doc)

    def route_screens_and_prices(self, method, path, q, doc):
        m = re.fullmatch
        g = m(r"/v1/appStoreVersionLocalizations/([^/]+)/appScreenshotSets", path)
        if g and method == "GET":
            return self.listing(self.all("appScreenshotSets", g.group(1)))
        if method == "POST" and path == "/v1/appScreenshotSets":
            lid = doc["data"]["relationships"]["appStoreVersionLocalization"]["data"]["id"]
            res = self.add("appScreenshotSets", doc["data"]["attributes"], parent=lid)
            return self.reply({"data": self.ser(res)}, 201)
        g = m(r"/v1/appScreenshotSets/([^/]+)/appScreenshots", path)
        if g and method == "GET":
            shots = self.all("appScreenshots", g.group(1))
            order = self.order.get(g.group(1))
            if order:
                shots.sort(key=lambda s: order.index(s["id"]) if s["id"] in order else 99)
            return self.listing(shots)
        g = m(r"/v1/appScreenshotSets/([^/]+)/relationships/appScreenshots", path)
        if g and method == "PATCH":
            self.order[g.group(1)] = [d["id"] for d in doc["data"]]
            return 204, {}, b""
        if method == "POST" and path == "/v1/appScreenshots":
            return self.reserve_screenshot(doc)
        g = m(r"/v1/appScreenshots/([^/]+)", path)
        if g:
            return self.screenshot(method, g.group(1), doc)
        g = m(r"/v1/apps/([^/]+)/appPriceSchedule", path)
        if g and method == "GET":
            found = self.all("appPriceSchedules", g.group(1))
            if not found:
                if self.price_stub:
                    return self.reply({"data": {"type": "appPriceSchedules", "id": g.group(1)}})
                return self.err(404, "NOT_FOUND", "The resource does not exist.")
            return self.single(found[0])
        g = m(r"/v1/apps/([^/]+)/appPricePoints", path)
        if g and method == "GET":
            terr = q.get("filter[territory]")
            points = [p for p in self.all("appPricePoints") if p["parent"] == terr]
            return self.listing(points)
        g = m(r"/v1/appPriceSchedules/([^/]+)/manualPrices", path)
        if g and method == "GET":
            if self.one("appPriceSchedules", g.group(1)) is None:
                return self.err(404, "NOT_FOUND", "There is no resource of type 'null' with id '%s'" % g.group(1),
                                "The specified resource does not exist")
            prices = self.all("appPrices", g.group(1))
            included = []
            for p in prices:
                pp = self.one("appPricePoints", p["rels"]["appPricePoint"]["id"])
                included.append(self.ser(pp))
            return self.listing(prices, included)
        if method == "POST" and path == "/v1/appPriceSchedules":
            data = doc["data"]
            app_id = data["relationships"]["app"]["data"]["id"]
            sched = self.add("appPriceSchedules", {}, parent=app_id,
                             rels={"baseTerritory": data["relationships"]["baseTerritory"]["data"]})
            for inc in doc.get("included", []):
                start = (inc.get("attributes") or {}).get("startDate")
                if not (isinstance(start, str) and re.fullmatch(r"\d{4}-\d{2}-\d{2}", start)):
                    return self.err(409, "ENTITY_ERROR.ATTRIBUTE.REQUIRED", "startDate is required")
                self.add("appPrices", inc.get("attributes"), parent=sched["id"],
                         rels={"appPricePoint": inc["relationships"]["appPricePoint"]["data"]})
            return self.reply({"data": self.ser(sched)}, 201)
        g = m(r"/v1/apps/([^/]+)/appAvailabilityV2", path)
        if g and method == "GET":
            found = self.all("appAvailabilities", g.group(1))
            if not found:
                return self.err(404, "NOT_FOUND", "The resource does not exist.")
            return self.single(found[0])
        if method == "GET" and path == "/v1/territories":
            return self.listing(self.all("territories"))
        if method == "POST" and path == "/v2/appAvailabilities":
            data = doc["data"]
            app_id = data["relationships"]["app"]["data"]["id"]
            if self.all("appAvailabilities", app_id):
                return self.err(409, "ENTITY_ERROR", "availability already exists")
            refs = [r["id"] for r in data["relationships"]["territoryAvailabilities"]["data"]]
            included = {i["id"]: i for i in doc.get("included", [])}
            if sorted(refs) != sorted(included) or not refs:
                return self.err(409, "ENTITY_ERROR", "territoryAvailabilities do not match the included resources")
            res = self.add("appAvailabilities", data.get("attributes"), parent=app_id)
            for ref in refs:
                inc = included[ref]
                terr = inc["relationships"]["territory"]["data"]["id"]
                if self.one("territories", terr) is None:
                    return self.err(409, "ENTITY_ERROR", "unknown territory")
                self.add("territoryAvailabilities", {"available": inc["attributes"]["available"]},
                         parent=res["id"], rels={"territory": {"type": "territories", "id": terr}})
            return self.reply({"data": self.ser(res)}, 201)
        g = m(r"/v2/appAvailabilities/([^/]+)/territoryAvailabilities", path)
        if g and method == "GET":
            return self.listing(self.all("territoryAvailabilities", g.group(1)))
        return self.err(404, "NOT_FOUND", "no route for %s %s" % (method, path))

    # ------------------------------------------------------------ helpers
    def patch_attrs(self, rtype, rid, doc):
        res = self.one(rtype, rid)
        if res is None:
            return self.err(404, "NOT_FOUND", "The resource does not exist.")
        data = doc["data"]
        assert data["type"] == rtype and data["id"] == rid, "body type or id does not match the path"
        new = data.get("attributes") or {}
        if rtype == "appStoreVersions" and "versionString" in new and \
                res["attributes"].get("appVersionState") not in (
                    "PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED"):
            return self.err(409, "STATE_ERROR", "the version is not editable")
        if rtype == "appStoreVersionLocalizations":
            bad = self.reject_whats_new(res["parent"], new)
            if bad:
                return bad
        res["attributes"].update(new)
        return self.single(res)

    def reject_whats_new(self, version_id, attributes):
        if not self.first_version_rejects_whats_new or not attributes.get("whatsNew"):
            return None
        others = [v for v in self.all("appStoreVersions")
                  if v["id"] != version_id and v["attributes"].get("appVersionState") == "READY_FOR_SALE"]
        if others:
            return None
        return self.err(409, "ENTITY_ERROR.ATTRIBUTE.INVALID.NOT_EDITABLE",
                        "whatsNew cannot be edited for the first version", "An attribute value is not valid.")

    def create_localisation(self, rtype, parent_rel, doc):
        data = doc["data"]
        pid = data["relationships"][parent_rel]["data"]["id"]
        attributes = data["attributes"]
        if rtype == "appStoreVersionLocalizations":
            bad = self.reject_whats_new(pid, attributes)
            if bad:
                return bad
        for other in self.all(rtype, pid):
            if other["attributes"].get("locale") == attributes.get("locale"):
                return self.err(409, "ENTITY_ERROR.RELATIONSHIP.INVALID", "locale already exists")
        res = self.add(rtype, attributes, parent=pid)
        return self.reply({"data": self.ser(res)}, 201)

    def reserve_screenshot(self, doc):
        attributes = doc["data"]["attributes"]
        set_id = doc["data"]["relationships"]["appScreenshotSet"]["data"]["id"]
        if len(self.all("appScreenshots", set_id)) >= 10:
            return self.err(409, "ENTITY_ERROR", "a set holds at most 10 screenshots")
        res = self.add("appScreenshots", {
            "fileName": attributes["fileName"], "fileSize": attributes["fileSize"],
            "sourceFileChecksum": None, "uploaded": False,
            "assetDeliveryState": {"state": "AWAITING_UPLOAD", "errors": [], "warnings": []},
        }, parent=set_id)
        ops, offset, index = [], 0, 0
        while offset < attributes["fileSize"]:
            length = min(self.part_size, attributes["fileSize"] - offset)
            ops.append({"method": "PUT", "offset": offset, "length": length,
                        "url": "https://%s/%s/%d" % (UPLOAD_HOST, res["id"], index),
                        "requestHeaders": [{"name": "Content-Type", "value": "image/png"},
                                           {"name": "X-Fake-Part", "value": str(index)}]})
            offset += length
            index += 1
        res["attributes"]["uploadOperations"] = ops
        return self.reply({"data": self.ser(res)}, 201)

    def handle_upload(self, method, path, headers, body):
        self.upload_requests.append((method, path, dict(headers), len(body or b"")))
        if "Authorization" in headers:
            return 400, {}, b"credentials must not go to the upload host"
        shot_id, index = path.strip("/").split("/")
        index = int(index)
        shot = self.one("appScreenshots", shot_id)
        op = shot["attributes"]["uploadOperations"][index]
        if method != "PUT" or headers.get("Content-Type") != "image/png" \
                or headers.get("X-Fake-Part") != str(index) or len(body) != op["length"]:
            return 400, {}, b"bad part"
        if self.corrupt and index == 0:
            body = bytes([body[0] ^ 0xFF]) + body[1:]
        self.parts.setdefault(shot_id, {})[index] = body
        return 200, {}, b""

    def screenshot(self, method, sid, doc):
        shot = self.one("appScreenshots", sid)
        if shot is None:
            return self.err(404, "NOT_FOUND", "The resource does not exist.")
        if method == "DELETE":
            del self.db["appScreenshots"][sid]
            return 204, {}, b""
        if method == "GET":
            if self.polls.get(sid, 0) > 0:
                self.polls[sid] -= 1
                if self.polls[sid] == 0:
                    shot["attributes"]["assetDeliveryState"]["state"] = "COMPLETE"
            return self.single(shot)
        if method == "PATCH":
            new = doc["data"].get("attributes") or {}
            if new.get("uploaded"):
                have = self.parts.get(sid, {})
                ops = shot["attributes"]["uploadOperations"]
                if sorted(have) != list(range(len(ops))):
                    return self.err(409, "ENTITY_ERROR", "not all parts were uploaded")
                blob = b"".join(have[i] for i in range(len(ops)))
                if hashlib.md5(blob).hexdigest() != new.get("sourceFileChecksum"):
                    shot["attributes"]["assetDeliveryState"] = {"state": "FAILED", "errors": [
                        {"code": "CHECKSUM", "description": "checksum mismatch"}], "warnings": []}
                else:
                    self.uploaded[sid] = blob
                    shot["attributes"]["assetDeliveryState"]["state"] = "UPLOAD_COMPLETE"
                    self.polls[sid] = self.upload_polls
                shot["attributes"]["uploaded"] = True
                shot["attributes"]["sourceFileChecksum"] = new.get("sourceFileChecksum")
            return self.single(shot)
        return self.err(405, "METHOD", "not allowed")


# ------------------------------------------------------------- scenarios ---

AGE_KEYS = ("advertising", "gambling", "violenceRealistic", "alcoholTobaccoOrDrugUseOrReferences",
            "messagingAndChat", "userGeneratedContent")


def build_app(bundle_id, public_key=None, complete=True, locale="en-US", **kw):
    """Return a FakeAsc holding one app. complete=False builds a fresh, empty record."""
    fake = FakeAsc(bundle_id, public_key=public_key, **kw)
    for code in ("USA", "IRL", "GBR", "FRA", "DEU"):
        fake.add("territories", {}, rid=code)
    app = fake.add("apps", {"bundleId": bundle_id, "primaryLocale": locale,
                            "contentRightsDeclaration": "DOES_NOT_USE_THIRD_PARTY_CONTENT" if complete else None},
                   rid="900001")
    version = fake.add("appStoreVersions", {"versionString": "1.0", "platform": "IOS",
                                            "appVersionState": "PREPARE_FOR_SUBMISSION",
                                            "copyright": "2026 Example Test" if complete else None},
                       parent=app["id"])
    pre = fake.add("preReleaseVersions", {"version": "1.0"}, parent=app["id"])
    build = fake.add("builds", {"version": "7", "processingState": "VALID", "expired": False,
                                "uploadedDate": "2026-09-01T10:00:00Z", "usesNonExemptEncryption": False},
                     parent=app["id"], rels={"preReleaseVersion": {"type": "preReleaseVersions", "id": pre["id"]}})
    if complete:
        version["rels"]["build"] = {"type": "builds", "id": build["id"]}
    vloc = None
    if complete:
        vloc = fake.add("appStoreVersionLocalizations", {
            "locale": locale, "description": "A test description.", "keywords": "one,two",
            "promotionalText": "Promo", "whatsNew": "", "supportUrl": "https://example.test/support",
            "marketingUrl": "https://example.test"}, parent=version["id"])
    info = fake.add("appInfos", {"state": "PREPARE_FOR_SUBMISSION"}, parent=app["id"],
                    rels=({"primaryCategory": {"type": "appCategories", "id": "DEVELOPER_TOOLS"},
                           "secondaryCategory": {"type": "appCategories", "id": "PRODUCTIVITY"}} if complete else {}))
    if complete:
        fake.add("appInfoLocalizations", {"locale": locale, "name": "Test App", "subtitle": "A subtitle",
                                          "privacyPolicyUrl": "https://example.test/privacy"}, parent=info["id"])
    fake.add("ageRatingDeclarations", {k: (("NONE" if k != "advertising" else False) if complete else None)
                                       for k in AGE_KEYS} | {"kidsAgeBand": None}, parent=info["id"])
    if complete:
        fake.add("appStoreReviewDetails", {
            "notes": "Review notes.", "demoAccountRequired": False, "contactFirstName": "Test",
            "contactLastName": "User", "contactPhone": "+353 1 555 0100", "contactEmail": "test@example.test"},
            parent=version["id"])
        for stype in ("APP_IPHONE_67", "APP_IPAD_PRO_3GEN_129"):
            sset = fake.add("appScreenshotSets", {"screenshotDisplayType": stype}, parent=vloc["id"])
            for i in range(2):
                fake.add("appScreenshots", {"fileName": "%02d.png" % (i + 1), "fileSize": 10,
                                            "assetDeliveryState": {"state": "COMPLETE"}}, parent=sset["id"])
        fake.add("appAvailabilities", {}, parent=app["id"], rid="av-1")
        for i in range(3):
            fake.add("territoryAvailabilities", {"available": True}, parent="av-1")
    fake.add("appPricePoints", {"customerPrice": "0.0"}, parent="USA", rid="pp-free")
    fake.add("appPricePoints", {"customerPrice": "0.99"}, parent="USA", rid="pp-paid")
    if complete:
        sched = fake.add("appPriceSchedules", {}, parent=app["id"])
        fake.add("appPrices", {}, parent=sched["id"], rels={"appPricePoint": {"type": "appPricePoints", "id": "pp-free"}})
    return fake
