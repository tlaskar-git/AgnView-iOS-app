# AgnView iOS

AgnView iOS is the iOS and iPadOS companion for the public [AgnView hub](https://github.com/tlaskar-git/AgnView). It pairs with a hub by QR scan and shows the Console, Sessions, Pipelines and Usage screens.

## Status

Design prototype only. The app is under construction.

## Folder map

| Path | Content |
|---|---|
| `mockups/ios-prototype.html` | Clickable HTML prototype of the app |
| `docs/MOBILE-SPEC.md` | Mobile specification and design review decisions |
| `index.html` | Landing page |
| `assets/` | Images, fonts, icons and the vendored Tailwind play script |
| `.githooks/` | Local pre-commit hook |
| `.github/` | Workflows and Dependabot configuration |

## Builds

Xcode builds run only in GitHub Actions on macOS runners. Nothing builds locally.

## Open the mockup

Open `mockups/ios-prototype.html` in a browser.

## Release setup

See `docs/RELEASE-SETUP.md`, coming with the CI setup.

## Security

- The repo holds no secrets. Signing material, keys and environment files are ignored.
- gitleaks runs on every commit (local hook) and on every push and pull request (GitHub Actions).
- Enable the local hook with `git config core.hooksPath .githooks`. It needs gitleaks on the PATH.
- Report problems as described in `SECURITY.md`.
