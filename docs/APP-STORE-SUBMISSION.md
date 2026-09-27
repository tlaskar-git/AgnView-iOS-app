# App Store submission checklist

This is the operator's list for the first submission of AgnView for iPhone and iPad. Work top to bottom. Each step says where to click and which value to enter.

The app record already exists in App Store Connect under the name AgnView. The app is free.

## What the automation sets and what stays manual

The App Store Connect workflow reads [AppStore/listing.json](../AppStore/listing.json) and sets what the API allows. Check its run summary before you rely on this table. If a field shows as not set, enter it by hand from the same file.

| Item | Who sets it |
|---|---|
| Name, subtitle, promotional text, description, keywords, what's new | Workflow, from listing.json |
| Support URL, marketing URL, privacy policy URL | Workflow, from listing.json |
| Copyright, categories, content rights declaration | Workflow, from listing.json |
| Age rating answers | Workflow, from listing.json (values are in step 6 for a manual check) |
| Review notes and the "sign-in required" flag | Workflow, from listing.json |
| App Privacy questionnaire | Manual, the API cannot set it (step 3) |
| Pricing and availability | Manual (steps 4 and 5) |
| Export compliance | Manual, already answered (step 7) |
| App Review contact fields | Manual, personal details never go in the repository (step 8) |
| Attach the build to the version | Manual (step 9) |
| Upload screenshots | Manual unless the workflow run summary says it uploaded them (step 10) |
| Release option and Submit for Review | Manual (steps 11 and 12) |

## 1. Upload a build

1. Push a version tag only when you are ready. The release workflow signs the build and sends it to TestFlight. This branch does not do that.
2. Wait until App Store Connect finishes processing the build. It shows under TestFlight, then under the app version.

## 2. Open the version page

App Store Connect, My Apps, AgnView, iOS App, the version in Prepare for Submission. Confirm the text fields match listing.json. The name is AgnView. The subtitle is Watch your AI coding agents.

## 3. App Privacy

App Store Connect, AgnView, App Privacy, Get Started (or Edit).

- Do you or your third-party partners collect data from this app? Choose **No**.
- Result: **Data Not Collected**. Publish it.

Why each category is not collected:

| Category | Why it is not collected |
|---|---|
| Contact info, health, financial, sensitive info | The app has no account and no form for them. |
| Location | The app never reads the location. |
| User content (prompts, files) | Prompts and console output travel between the phone and the user's own computer. The developer never receives them. |
| Browsing and search history | Not read. |
| Identifiers | The app reads no advertising id and creates no user id. |
| Purchases | The app has no purchases. |
| Usage data and diagnostics | The app has no analytics and no crash reporting service. |
| Other data | The pairing key stays in the device Keychain and never leaves the phone except to reach the user's own computer. |

The iroh relay servers of a third party see connection metadata. That data is not collected by the developer or sent to the developer, so it is not declared. The privacy policy explains it.

## 4. Pricing

App Store Connect, AgnView, Pricing and Availability, Price Schedule: choose **Free** (price tier 0).

## 5. Availability

Same page, App Availability. Choose the countries and regions where you want the app. The export answer in step 7 says the app is not distributed in France, so **remove France** from the list.

## 6. Age rating

App Store Connect, AgnView, App Information, Age Rating, Edit. Answer **None** to every content question and **No** to every yes-or-no question:

- Violence, cartoon or fantasy: None. Violence, realistic: None. Prolonged graphic or sadistic realistic violence: None.
- Sexual content or nudity: None. Graphic sexual content and nudity: None. Mature or suggestive themes: None.
- Horror or fear themes: None. Profanity or crude humour: None.
- Alcohol, tobacco or drug use or references: None. Guns or other weapons: None.
- Medical or treatment information: None. Simulated gambling: None. Contests: None.
- Gambling: No. Loot boxes: No. Advertising: No. User-generated content: No. Messaging and chat: No.
- Unrestricted web access: No. Parental controls: No. Age assurance: No. Health or wellness topics: No. Social media: No.

The expected rating is 4+. The full attribute list is in listing.json under ageRating.

## 7. Export compliance

Already answered. If App Store Connect asks again for this build, give the same answers:

- Does the app use encryption? **Yes.**
- Does it use only standard encryption algorithms (the iOS system encryption and the standard algorithms in iroh, which are exempt)? **Yes.**
- Is the app distributed in France? **No.** France is off the availability list.

Do not add ITSAppUsesNonExemptEncryption to the app configuration. You answer in App Store Connect and the app makes no claim.

## 8. App Review contact and notes

Version page, App Review Information.

| Field | Value |
|---|---|
| Sign-in required | **No** (leave the demo account fields empty) |
| First name | `<your first name>` |
| Last name | `<your last name>` |
| Phone number | `<your phone number with country code>` |
| Email | `<your contact email>` |
| Notes | Paste the reviewNotes text from listing.json, or check that the workflow set it |

You type your own contact details in App Store Connect only. They never go in this repository, an issue or a pull request.

## 9. Attach the build

Version page, Build, the plus button (Add Build). Choose the processed build. The app icon on the version page shows only after a build is attached. If the icon is blank, attach the build first.

## 10. Screenshots

The appstore-screenshots workflow builds them in demo mode. Run it from the Actions tab (Run workflow), then download the artifact named appstore-screenshots.

| Files | Upload to |
|---|---|
| iphone-6.9-01 to iphone-6.9-06 | iPhone, 6.9-inch display, 1320 by 2868 pixels |
| ipad-13-01 to ipad-13-06 | iPad, 13-inch display, 2064 by 2752 pixels |
| iphone-6.9-07 and 08, ipad-13-07 and 08 | Optional. Dark mode extras. Add them after the six main screens. |

App Store Connect scales the 6.9-inch iPhone set down for smaller phones. Upload the six main screens in numeric order. The screenshots show demo data and the demo banner. That is intended.

## 11. Version release

Version page, Version Release. Choose one:

- **Manually release this version** to control the day it goes live. Recommended for the first release.
- **Automatically release this version** to go live as soon as Apple approves it.

## 12. Submit

1. Check that the version page shows no red warnings.
2. Click **Add for Review**, then **Submit to App Review**.
3. Watch for the review result by email and in App Store Connect. If Apple asks a question, the demo mode and the review notes answer most of them.

## Before you submit: last checks

- The privacy policy link opens: https://github.com/tlaskar-git/AgnView-iOS-app/blob/main/PRIVACY.md
- The support link opens: https://github.com/tlaskar-git/AgnView-iOS-app/issues
- Open the build on a real iPhone. Tap Try the demo. Visit every tab.
- Pair once with the desktop app to confirm the real route still works. See [DEVICE-TEST.md](DEVICE-TEST.md).
