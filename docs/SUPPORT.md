# AgnView for iOS support

AgnView for iOS is a companion app. It needs the free AgnView app on your Windows PC or Mac. The phone app shows what your coding agents do and lets you send them prompts.

## Try it without a computer

Open the app and tap Try the demo. Every screen works with built-in sample data. Nothing is connected in the demo. Tap Exit demo in Settings to leave it.

## Install the desktop app

1. Open https://github.com/tlaskar-git/AgnView/releases/latest on your computer.
2. Download the installer for Windows or the build for Mac.
3. Install it and start AgnView.
4. Install and sign in to the agents you want to use (Claude Code, Codex, AntiGravity). AgnView finds them on your computer.

For remote access away from your Wi-Fi, use AgnView 0.1.12 or later. To create pipelines away from your Wi-Fi, use 0.1.13 or later.

## Pair your phone

1. In AgnView on your computer, open the pairing screen and show the pairing QR code.
2. On the same Wi-Fi, turn on Allow phones on my network in AgnView. This gives the LAN route.
3. On your phone, open AgnView and tap Scan QR code. Allow the camera.
4. Allow Local Network when iOS asks.
5. The machine appears in Settings. The route pill shows LAN, Direct or Relay.

You can paste the pairing link instead of scanning. Use Paste pairing link on the pairing screen.

## Routes

| Route | Meaning |
|---|---|
| LAN | Same Wi-Fi as your computer. Everything works. |
| Direct | Away from Wi-Fi, direct peer-to-peer connection through iroh. |
| Relay | Away from Wi-Fi, through a public iroh relay. The traffic stays encrypted end to end. |
| Demo | Built-in sample data. No connection. |

## Troubleshooting

The full checklist with expected results is in [DEVICE-TEST.md](DEVICE-TEST.md). The most common items:

| Symptom | Fix |
|---|---|
| Camera denied | iOS Settings, AgnView, Camera: switch on. Or paste the pairing link. See section 8 of [DEVICE-TEST.md](DEVICE-TEST.md). |
| Local Network denied | iOS Settings, AgnView, Local Network: switch on. Reopen the app. |
| The hub rejected this pairing | The key no longer matches. Scan the current QR code again. |
| Can't reach this hub | AgnView is closed or the computer sleeps. Open AgnView on the computer. |
| Stuck on Relay on the same Wi-Fi | Allow phones on my network is off, or the Wi-Fi isolates devices. See Part C of [DEVICE-TEST.md](DEVICE-TEST.md). |
| Prompts, Usage or Pipelines need the same Wi-Fi | The computer runs an older AgnView. Update it. See Part B of [DEVICE-TEST.md](DEVICE-TEST.md). |

## Remove a computer

Open Settings, choose the machine, then tap Remove from this phone. This deletes the stored key on the phone. The key stays valid on the computer until you regenerate it there. Deleting the app removes everything.

## Report a problem

Open an issue: https://github.com/tlaskar-git/AgnView-iOS-app/issues

Say which screen, which route label and the exact message you saw. Do not post pairing keys, QR codes, machine names or addresses.

## Privacy

Read the [privacy policy](../PRIVACY.md).
