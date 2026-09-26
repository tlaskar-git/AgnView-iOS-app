# Release setup

This guide sets up signed TestFlight releases from a Windows PC with no Mac. All signing happens on a GitHub macOS runner. You create the signing material once, store it as GitHub environment secrets, and push a version tag to release.

The release workflow is `.github/workflows/release.yml`. It has not been run end to end yet, because the secrets did not exist when it was written. Expect to fix small problems on the first real release.

## a. Prerequisites

- Membership of the Apple Developer Program (paid, individual or organisation).
- Admin access to this GitHub repository.
- Git for Windows, which includes Git Bash and `openssl`.
- An app icon. The build has no app icon yet, and App Store Connect rejects an upload without one. Add an asset catalogue with a 1024 by 1024 icon before the first release.

## b. The nine secrets

All nine are environment secrets of the GitHub environment named `release`.

| Secret | Holds | Comes from |
|---|---|---|
| `APPLE_TEAM_ID` | Ten character team identifier | developer.apple.com, Membership details |
| `APP_BUNDLE_ID` | Reverse-domain app identifier you register | You choose it, in step c4 |
| `APPLE_DISTRIBUTION_CERT_P12_BASE64` | Base64 of the certificate and private key bundle | Step c3 |
| `APPLE_DISTRIBUTION_CERT_PASSWORD` | Password of that bundle | You choose it in step c3 |
| `APPLE_PROVISIONING_PROFILE_BASE64` | Base64 of the App Store provisioning profile | Step c5 |
| `APPLE_PROVISIONING_PROFILE_NAME` | Name of that profile as shown on developer.apple.com | Step c5 |
| `ASC_API_KEY_ID` | Key identifier of the App Store Connect API key | Step c7 |
| `ASC_API_ISSUER_ID` | Issuer identifier of the team | Step c7 |
| `ASC_API_KEY_P8_BASE64` | Base64 of the downloaded `.p8` key file | Step c7 |

## c. Create each value on Windows

Work in a new folder outside the repository, for example `signing-work` in your user folder. Use Git Bash for the `openssl` commands.

### c1. Private key and certificate signing request

```
openssl genrsa -out dist.key 2048
openssl req -new -key dist.key -out dist.csr -subj "/CN=AgnView Distribution/emailAddress=user@example.com"
```

Use your own email address in place of the placeholder. The key file `dist.key` never leaves your PC.

### c2. Request the certificate

1. Open developer.apple.com, then Certificates, Identifiers and Profiles, then Certificates.
2. Select the plus button and choose Apple Distribution.
3. Upload `dist.csr`.
4. Download the resulting `distribution.cer`.

### c3. Build the .p12 bundle

```
openssl x509 -inform DER -in distribution.cer -out distribution.pem
openssl pkcs12 -export -inkey dist.key -in distribution.pem -out dist.p12
```

`openssl` asks for an export password. Choose a strong one. It becomes `APPLE_DISTRIBUTION_CERT_PASSWORD`. If the runner cannot read the bundle, add `-legacy` to the export command.

### c4. Register the App ID

1. In Certificates, Identifiers and Profiles, open Identifiers and select the plus button.
2. Choose App IDs, then App.
3. Enter a description and an explicit bundle identifier of your choice, in reverse-domain form.
4. Register it. The bundle identifier is `APP_BUNDLE_ID`.

### c5. Provisioning profile

1. Open Profiles and select the plus button.
2. Choose App Store Connect under Distribution.
3. Select the App ID from step c4 and the certificate from step c2.
4. Enter a profile name. This is `APPLE_PROVISIONING_PROFILE_NAME`.
5. Generate and download the `.mobileprovision` file.

### c6. App record in App Store Connect

1. Open appstoreconnect.apple.com, then Apps, then the plus button, then New App.
2. Choose iOS, enter a name, a language, the bundle identifier from step c4 and a SKU of your choice.
3. Create the record.

### c7. App Store Connect API key

1. In App Store Connect open Users and Access, then Integrations, then App Store Connect API.
2. Generate a team key with the App Manager role.
3. Note the Key ID (`ASC_API_KEY_ID`) and the Issuer ID (`ASC_API_ISSUER_ID`).
4. Download the `.p8` file. Apple offers the download only once.

### c8. Base64 encoding

In Git Bash:

```
base64 -w0 dist.p12 > dist.p12.b64
base64 -w0 profile.mobileprovision > profile.b64
base64 -w0 AuthKey_KEYID.p8 > key.b64
```

In PowerShell:

```
[Convert]::ToBase64String([IO.File]::ReadAllBytes("dist.p12")) | Set-Content dist.p12.b64
```

Copy the content of each `.b64` file into the matching secret. Use the team identifier from Membership details for `APPLE_TEAM_ID`.

## d. Enter the secrets

1. In the GitHub repository open Settings, then Environments, then `release`.
2. Under Environment secrets add each of the nine secrets.
3. Add a required reviewer to the environment, so every release needs your approval.
4. Delete the local `.b64` files, the `.csr`, `.cer`, `.pem`, `.mobileprovision` and any copy in the clipboard history.
5. Keep `dist.key`, `dist.p12`, the `.p8` file and the password offline, for example on an encrypted drive. Do not keep them in a synced folder or in this repository.

## e. Release

1. Merge the work to `main`.
2. Push a tag that starts with `v`, for example `v1.0.3`, from `main`. The workflow refuses a tag whose commit is not on `main`.
3. Open the run under Actions and approve the deployment to the `release` environment.
4. Wait for the run to finish, then wait for App Store Connect to finish processing the build.
5. In App Store Connect open TestFlight, add yourself as an internal tester, and accept the invitation.
6. Install the build with the TestFlight app on your device.

The marketing version comes from the tag. The build number comes from the workflow run number.

### Version numbers

The tag is the source of the released version. A release build takes `MARKETING_VERSION` from the tag without its leading `v` and `CURRENT_PROJECT_VERSION` from the workflow run number. Settings shows the marketing version only, for example `Version 1.0.3`. The build number sits in its own `Build` row in the About section and is never joined to the version.

`project.yml` also carries defaults for both values. Simulator builds, unit tests, UI tests and their screenshots use those defaults, so they must match the last released version. Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml` in the release pull request, then tag the merge commit with the same version.

Two checks guard this.

- `ci` reads `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` from `project.yml`, builds the simulator app and fails when its `Info.plist` differs. It also passes the version to the unit and UI tests, which fail when Settings shows another one.
- `release` and `release-preflight` read the `Info.plist` inside the archive right after `xcodebuild archive`. They fail when `CFBundleShortVersionString` differs from the tag without the leading `v`, or `CFBundleVersion` differs from the run number. The message shows both values. Versions are not secret.

## Preflight

The preflight checks the nine secrets and the whole signing chain without uploading anything. Run it before the first release and after any secret changes.

1. Open the repository on GitHub, then Actions, then `release-preflight`.
2. Select Run workflow on `main`.
3. Approve the run when the `release` environment asks.

The run checks the secrets and the icon, generates the project, imports the certificate into a temporary keychain, checks the profile, signs an archive, exports an IPA and validates it with App Store Connect. It never uploads the IPA and never publishes an artifact. The workflow deletes the keychain, profile and decoded files at the end. The `release` workflow runs the same input, icon and signing steps before it uploads.

Each line reads `PASS` or `FAIL`. No line ever shows a value. Fix the failing check like this.

| Failing check | What to fix |
|---|---|
| `APPLE_TEAM_ID`, `ASC_API_KEY_ID` format | 10 upper case letters or digits. The team ID is on the Membership page. The key ID is on the API key row. |
| `ASC_API_KEY_ID` and `APPLE_TEAM_ID` hold the same value | One of the two holds the wrong value. Enter the key ID from the API key row. |
| `ASC_API_ISSUER_ID` | A UUID from the top of the API keys page. |
| `APP_BUNDLE_ID` | Reverse-DNS, not `com.example`. Use the identifier of the registered App ID. |
| `APPLE_PROVISIONING_PROFILE_NAME` | Must not be empty. Copy the exact profile name. |
| Any `_BASE64` secret decodes | Encode the file again as one line, as in section c8. |
| `ASC_API_KEY_P8_BASE64` header | The file must be the `.p8` key, not another file. |
| `APPLE_PROVISIONING_PROFILE_BASE64` CMS | The file must be the `.mobileprovision` download. |
| `icon` | The icon must be 1024x1024 with no alpha channel. Run `python3 Tools/ci/check_icon.py <file>`. |
| `profile` Name | The name secret must equal the profile name in the Apple portal. |
| `profile` TeamIdentifier | The profile belongs to another team. Create a new profile. |
| `profile` application-identifier | The profile is for another App ID. Create a profile for the bundle ID in the secret. |
| `profile` expired | Create a new profile and update both profile secrets. |
| `profile` DeveloperCertificates mismatch | The check prints only counts and hints, never a value. `0 in common` means the profile was created for a different certificate than the one in the `.p12`. Edit the profile, select the certificate and download it again. `keychain has 0 signing identities` means the `.p12` imported no identity: check the password and that the `.p12` holds the private key. |

All signing tool output in the workflows passes through `Tools/ci/redact_log.py`, which removes certificate names, team IDs, UUIDs, hashes and profile paths before they reach the public log.
| Archive or export fails | Read the Xcode error. Usual causes are a wrong certificate password or a profile that does not match the App ID. |
| `altool` validation fails | Read the message. Usual causes are a wrong API key role, an app record that does not exist, or a build number that is not higher than the last upload. |

## f. Export compliance

Answer the export compliance question in App Store Connect when the first build appears. This repository makes no claim and sets no encryption key in the app configuration.

## g. What never goes in the repository or logs

- Private keys, `.p12`, `.p8`, `.cer`, `.mobileprovision` files and their base64 forms.
- Passwords, key identifiers, issuer identifiers and team identifiers.
- The real bundle identifier of your account. The repository holds the placeholder `com.example.agnview` and the release workflow replaces it from a secret.
- Personal names, email addresses, device names, hostnames, IP addresses and local file paths.
- Screenshots that show any of the above.

The release workflow masks every derived value, never prints a secret and never uploads the archive, the IPA or any signing file as an artifact.
