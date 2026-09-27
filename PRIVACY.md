# AgnView for iOS privacy policy

Effective date: 2026-09-26

AgnView for iOS is a companion app. It shows the output of AI coding agents that run on your own computer. This policy explains what the app does with data.

## Summary

- The app collects no personal data.
- The app has no account, no analytics, no advertising and no tracking.
- Nothing is sent to the developer.
- Your prompts and the console output travel only between your phone and your own computer.

## What the app stores on your phone

- The pairing key for each computer you pair. It is stored in the iOS Keychain on this device only. It does not sync to iCloud.
- The name of each paired computer, its network address and its pairing details. They are stored in the app storage on this device.
- The model and effort lists last read from your computer, so the menus work away from home.
- Your appearance choice (light, dark or system).

The app stores nothing else. It has no copy of your prompts or agent output after you close it.

Delete the app to remove all of this. You can also open Settings in the app and choose Remove from this phone for one computer. That deletes its stored key.

## Camera

The app asks for camera access to scan the pairing QR code that the AgnView app on your computer shows. The app does not store or send camera images. You can also paste the pairing link, which needs no camera.

## Local network

The app asks for local network access to talk to your own computer when both are on the same Wi-Fi. It does not scan or contact any other device.

## Away from your local network (iroh)

Away from your Wi-Fi, the app connects to your computer through iroh. iroh is an open source peer-to-peer connection protocol made by N0, Inc. (n0).

- The app tries a direct connection first.
- When a direct connection is not possible, iroh sends the traffic through a public relay server that n0 operates.
- The traffic is encrypted end to end between your phone and your computer. The iroh documentation states that relay servers cannot read it.
- A relay server and the discovery service that iroh uses still see connection metadata. That includes the network addresses of your phone and your computer, the iroh endpoint identifiers and the time and amount of traffic. The iroh documentation does not list every item, so treat all connection metadata as visible to n0.
- The developer of AgnView does not operate these servers and does not receive this metadata.

Read the iroh documentation at https://docs.iroh.computer for details. n0 is responsible for its own servers.

## Data sent to the developer

None. The app has no server of its own. The developer receives no data from the app.

## Demo mode

The demo mode inside the app uses built-in sample data. It makes no network connection, writes no key and stores nothing.

## Links

The app has links to the AgnView download page, this policy and the support page. They open in your browser. Those sites have their own policies.

## Children

The app is not directed at children. It collects no personal data from anyone, including children.

## Changes to this policy

The developer publishes changes in this file. The effective date at the top shows the latest version. The history is in the repository.

## Contact

Open an issue on the support page: https://github.com/tlaskar-git/AgnView-iOS-app/issues

Do not put secrets, pairing keys or personal details in a public issue.
