# Device test checklist

Use this list to test the TestFlight build on a real iPhone against the AgnView hub on Windows. Tick each box as you go. Write down any failure as described in the last section.

## 1. Before you start

- [ ] The iPhone runs iOS 17.5 or later.
- [ ] The TestFlight app is installed on the iPhone.
- [ ] The hub runs on the PC: AgnView for Windows, version 0.1.8 or later.
- [ ] The phone and the PC are on the same Wi-Fi.
- [ ] In the hub, **Allow phones on my network** is ON (tray menu or pairing screen). Part A needs it.
- [ ] If Windows asks to let the hub through the firewall, allow it on private networks.
- [ ] Claude Code, Codex and AntiGravity are installed on the PC if you want to test them.

## 2. Install

1. Open TestFlight on the iPhone.
2. Wait for the build to appear. It shows after Apple finishes processing.
3. Tap **Install**, then **Open**.
4. Allow **Camera** when iOS asks. The app needs it to scan the QR code.
5. Allow **Local Network** when iOS asks. The LAN route needs it.

## 3. Part A: same Wi-Fi

1. On the PC, open the hub's pairing QR code (the mobile option in the dashboard header, or see the hub's pairing screen).
2. On the phone, go to Settings, then **Add machine**, then scan the QR code.
3. [ ] The machine appears in the list.
4. [ ] The route label reads **LAN**.
5. Open **Console**.
6. [ ] Live output appears.
7. Send a short prompt to each agent that is installed on the PC.
   - [ ] Claude Code replies.
   - [ ] Codex replies.
   - [ ] AntiGravity replies.
8. Open **Sessions**, **Pipelines** and **Usage**.
   - [ ] Each screen loads.
   - [ ] Usage shows cards only for the providers the hub reports.

If anything fails, write down the screen, the route label and the exact on-screen message.

## 4. Part B: off the Wi-Fi

1. Turn Wi-Fi off on the phone. Keep cellular on.
2. Wait up to 60 seconds.
3. [ ] The route label changes to **Direct** or **Relay**.
4. [ ] Console live output continues.
5. [ ] The composer is disabled and shows: "Sending prompts needs your local network. Turn on Allow phones on my network in AgnView and join the same Wi-Fi."
6. [ ] Pipelines shows: "Pipelines need your local network."
7. [ ] Usage shows: "Usage needs your local network." The last Usage reading stays visible, greyed and dated.
8. [ ] Sessions shows the banner: "Showing sessions seen in the log stream"
9. Turn Wi-Fi back on.
10. [ ] The route label returns to **LAN**.

## 5. Part C: relay only

1. Keep Wi-Fi on.
2. In the hub, switch **Allow phones on my network** OFF.
3. [ ] The phone shows: "Connected through iroh only. Allow phones on my network is off on the hub."
4. Switch **Allow phones on my network** back ON.
5. [ ] The banner clears and the route returns to **LAN**. Scan the QR code again if the phone does not reconnect. The QR code always matches the mode that is on.

## 6. Part D: key regeneration and unpair

1. In the hub, regenerate the pairing key (see the hub's pairing screen for the control).
2. [ ] The phone shows: "The key was regenerated on the hub. Re-pair to continue."
3. Scan the new QR code to re-pair.
4. [ ] The machine connects again.
5. In the app, use **Remove from this phone**.
6. [ ] The phone shows: "Removed from this phone. The key stays valid on the hub until you regenerate it there."
7. [ ] The machine is gone from the list.

## 7. Part E: second hub (optional)

1. Pair a second machine with **Add machine**.
2. Use **Switch Machine** to move between the two.
3. [ ] Console and the route label follow the machine you pick.
4. Remove the second machine with **Remove from this phone**.

## 8. Troubleshooting

| Symptom | Cause and fix |
|---|---|
| Camera denied | iOS Settings, AgnView, Camera: switch on. Reopen the scanner. |
| Local Network denied | iOS Settings, AgnView, Local Network: switch on. Reopen the app. |
| QR code rejected | The payload is malformed, or it came from a newer hub than the app supports. Regenerate the code on the hub and scan again. Update the app if the hub is newer. |
| "The hub rejected this pairing. Scan the QR code again." | The key no longer matches. Scan the current QR code. |
| "Can't reach this hub. Check that AgnView is running on your computer." | The hub is closed or asleep. Open AgnView on the PC and check it is not quit from the tray. |
| Stuck on Relay although on the same Wi-Fi | Allow phones on my network is off, so the hub listens on the PC only. Switch it on and scan again. Guest Wi-Fi with client isolation also blocks LAN: use the main network. Check the Windows firewall prompt was allowed. |
| Build stuck on Missing Compliance | Answer the export compliance questions in App Store Connect. See docs/RELEASE-SETUP.md, section f. |

## 9. What to send back

For each part (A to E), send:

- Pass or fail.
- The route label you saw.
- The exact message text on screen, if any.

Do not send screenshots that show personal data, such as machine names, addresses or the pairing QR code.
