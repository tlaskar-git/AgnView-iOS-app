# AgnView iOS

AgnView iOS is the iOS and iPadOS companion for the public [AgnView hub](https://github.com/tlaskar-git/AgnView). It pairs with a hub by QR scan and shows the Console, Sessions, Pipelines and Usage screens.

## Status

Design prototype plus a SwiftUI app shell with placeholder screens. Pairing and live hub access are not built yet.

## Folder map

| Path | Content |
|---|---|
| `mockups/ios-prototype.html` | Clickable HTML prototype of the app |
| `docs/MOBILE-SPEC.md` | Mobile specification and design review decisions |
| `index.html` | Landing page |
| `assets/` | Images, fonts, icons and the vendored Tailwind play script |
| `.githooks/` | Local pre-commit hook |
| `.github/` | Workflows and Dependabot configuration |
| `PRIVACY.md` | Privacy policy of the app |
| `docs/SUPPORT.md` | Install, pairing and troubleshooting help |
| `docs/APP-STORE-SUBMISSION.md` | Operator checklist for App Store Connect |
| `AppStore/listing.json` | Store listing text and age rating, checked by `Tools/ci/test_listing.py` |
| `Sources/AgnView/Demo/` | Demo mode: a built-in sample hub for App Review and first look |

## Builds

Xcode builds run only in GitHub Actions on macOS runners. Nothing builds locally.

## Open the mockup

Open `mockups/ios-prototype.html` in a browser.

## Release setup

See [docs/RELEASE-SETUP.md](docs/RELEASE-SETUP.md) for the signing secrets and the TestFlight release steps.

## CI

- `ci.yml` runs on every push and pull request. It generates the Xcode project with XcodeGen, starts the mock hub, then builds and runs unit and UI tests on an iPhone and an iPad simulator. Screenshots of each screen are kept as workflow artifacts for 14 days.
- `release.yml` runs when a tag starting with `v` is pushed. It signs and uploads a build to TestFlight and uses the `release` environment secrets. It has not been tested end to end.
- `gitleaks.yml` scans the repository history.
- The Xcode project is generated from `project.yml` and is not committed.
- [docs/DEVICE-TEST.md](docs/DEVICE-TEST.md) is the checklist for testing the TestFlight build on a real iPhone.
- `Tools/mock-hub/mock_hub.py` is a placeholder-only hub for tests. It binds to the loopback address.

## Security

- The repo holds no secrets. Signing material, keys and environment files are ignored.
- gitleaks runs on every commit (local hook) and on every push and pull request (GitHub Actions).
- Enable the local hook with `git config core.hooksPath .githooks`. It needs gitleaks on the PATH.
- Report problems as described in `SECURITY.md`.
