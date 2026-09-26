#!/usr/bin/env python3
"""Checks AppStore/listing.json: exact keys, field limits, age rating names,
links that match the app and text that follows the house rules.

Run: python3 Tools/ci/test_listing.py
"""
import json
import os
import re
import sys
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
LISTING = os.path.join(ROOT, "AppStore", "listing.json")

KEYS = [
    "locale", "name", "subtitle", "promotionalText", "description", "keywords",
    "whatsNew", "supportUrl", "marketingUrl", "privacyPolicyUrl", "copyright",
    "primaryCategory", "secondaryCategory", "contentRightsDeclaration",
    "ageRating", "reviewNotes", "reviewDemoRequired",
]

LIMITS = {
    "name": 30, "subtitle": 30, "promotionalText": 170, "keywords": 100,
    "description": 4000, "whatsNew": 4000, "reviewNotes": 4000,
}

# Attribute names of ageRatingDeclarations in the App Store Connect API
# (AgeRatingDeclarationUpdateRequest). Frequency questions take NONE,
# INFREQUENT_OR_MILD or FREQUENT_OR_INTENSE. The others are booleans.
AGE_STRINGS = {
    "alcoholTobaccoOrDrugUseOrReferences", "contests", "gamblingSimulated",
    "gunsOrOtherWeapons", "horrorOrFearThemes", "matureOrSuggestiveThemes",
    "medicalOrTreatmentInformation", "profanityOrCrudeHumor",
    "sexualContentGraphicAndNudity", "sexualContentOrNudity",
    "violenceCartoonOrFantasy", "violenceRealistic",
    "violenceRealisticProlongedGraphicOrSadistic",
}
AGE_BOOLEANS = {
    "advertising", "ageAssurance", "gambling", "healthOrWellnessTopics",
    "lootBox", "messagingAndChat", "parentalControls", "socialMedia",
    "socialMediaAgeRestricted", "unrestrictedWebAccess", "userGeneratedContent",
}

# Words that must never appear in a public file. They are split so this file
# does not hold them whole.
PRIVATE = [
    "ta" + "her", "las" + "kar", "kp" + "mg", "slo" + "bal", "vps" + "0",
    "home" + "lab", "gma" + "il", "192." + "168", "10.0." + "0", "C:" + "\\Users", "D:" + "\\AI",
]


def load():
    with open(LISTING, encoding="utf-8") as fh:
        return json.load(fh)


def app_links():
    with open(os.path.join(ROOT, "Sources", "AgnView", "AppLinks.swift"), encoding="utf-8") as fh:
        text = fh.read()
    found = {}
    for name in ("getDesktop", "privacyPolicy", "support"):
        match = re.search(r"static let %s = link\(\"([^\"]+)\"\)" % name, text)
        found[name] = match.group(1) if match else None
    return found


class ListingTest(unittest.TestCase):
    def setUp(self):
        self.data = load()

    def test_exact_keys_in_order(self):
        self.assertEqual(list(self.data.keys()), KEYS)

    def test_field_limits(self):
        for key, limit in LIMITS.items():
            self.assertLessEqual(len(self.data[key]), limit, key)
            self.assertGreater(len(self.data[key].strip()), 0, key)

    def test_keywords_have_no_spaces_or_repeats(self):
        words = self.data["keywords"].split(",")
        self.assertEqual(len(words), len(set(w.lower() for w in words)))
        self.assertTrue(all(w == w.strip() and w for w in words))

    def test_fixed_values(self):
        d = self.data
        self.assertEqual(d["locale"], "en-US")
        self.assertTrue(d["name"].startswith("AgnView"))
        self.assertEqual(d["primaryCategory"], "DEVELOPER_TOOLS")
        self.assertEqual(d["secondaryCategory"], "PRODUCTIVITY")
        self.assertEqual(d["contentRightsDeclaration"], "DOES_NOT_USE_THIRD_PARTY_CONTENT")
        self.assertIs(d["reviewDemoRequired"], False)
        self.assertIn("AgnView contributors", d["copyright"])

    def test_age_rating_names_and_values(self):
        rating = self.data["ageRating"]
        self.assertEqual(set(rating), AGE_STRINGS | AGE_BOOLEANS)
        for key in AGE_STRINGS:
            self.assertEqual(rating[key], "NONE", key)
        for key in AGE_BOOLEANS:
            self.assertIs(rating[key], False, key)

    def test_urls_match_the_app(self):
        links = app_links()
        self.assertEqual(self.data["privacyPolicyUrl"], links["privacyPolicy"])
        self.assertEqual(self.data["supportUrl"], links["support"])
        self.assertIn(links["getDesktop"].replace("https://", "").rsplit("/releases", 1)[0],
                      self.data["marketingUrl"] + "/")
        for key in ("supportUrl", "marketingUrl", "privacyPolicyUrl"):
            self.assertTrue(self.data[key].startswith("https://github.com/tlaskar-git/"), key)

    def test_description_leads_with_the_desktop_requirement(self):
        first = self.data["description"].split("\n\n")[0]
        self.assertIn("desktop app", first)
        self.assertIn("Windows", first)
        self.assertIn("demo", self.data["description"].lower())
        for name in ("Claude Code", "Codex", "AntiGravity"):
            self.assertIn(name, self.data["description"])
        self.assertIn("trademarks", self.data["description"])

    def test_review_notes_explain_the_demo(self):
        notes = self.data["reviewNotes"]
        self.assertIn("Try the demo", notes)
        self.assertIn("iroh", notes)
        self.assertIn("No sign-in", notes)

    def test_house_rules(self):
        blob = json.dumps(self.data, ensure_ascii=False)
        self.assertNotIn("—", blob, "em dash")
        self.assertIsNone(re.search("[\U0001F000-\U0001FAFF☀-➿]", blob), "emoji")
        # The repository owner name is allowed only inside repository links.
        cleaned = blob.replace("github.com/tlaskar-git/", "github.com/OWNER/")
        for word in PRIVATE:
            self.assertNotIn(word.lower(), cleaned.lower(), word)


class DocumentsTest(unittest.TestCase):
    def read(self, *parts):
        with open(os.path.join(ROOT, *parts), encoding="utf-8") as fh:
            return fh.read()

    def test_privacy_policy(self):
        text = self.read("PRIVACY.md")
        self.assertIn("Effective date: 2026-09-26", text)
        for word in ("iroh", "Keychain", "camera", "Children", "issues"):
            self.assertIn(word.lower(), text.lower(), word)

    def test_support_and_submission_documents(self):
        self.assertIn("Try the demo", self.read("docs", "SUPPORT.md"))
        text = self.read("docs", "APP-STORE-SUBMISSION.md")
        for word in ("Data Not Collected", "Free", "France", "Add for Review", "ITSAppUsesNonExemptEncryption"):
            self.assertIn(word, text, word)

    def test_documents_have_no_private_words_or_em_dashes(self):
        for parts in (("PRIVACY.md",), ("docs", "SUPPORT.md"), ("docs", "APP-STORE-SUBMISSION.md")):
            text = self.read(*parts)
            self.assertNotIn("—", text, parts)
            cleaned = text.replace("github.com/tlaskar-git/", "github.com/OWNER/").lower()
            for word in PRIVATE:
                self.assertNotIn(word.lower(), cleaned, (parts, word))


if __name__ == "__main__":
    unittest.main(verbosity=1)
