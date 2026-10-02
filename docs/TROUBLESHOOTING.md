# Troubleshooting

Start with the two device labels in ScrollFix. They show the macOS baseline or the expected direction for recognized streams, and **Hilfe & Status** shows the macOS baseline, permission, and filter status.

## The mouse already feels right with the fix off

That can be correct. With macOS “Natural scrolling” **off**, a mechanical wheel is already classic. The trackpad is then also classic. Turn on **Fix aktiv** if you want recognized trackpad gestures corrected while keeping the wheel classic. The app shows **Trackpad: Natürlich (erkannt)** and **Mausrad: Klassisch (macOS)**. For the most predictable result, turn macOS Natural scrolling **on** and let ScrollFix correct recognized wheel ticks.

## “Fix aktiv” is on, but the status says “PRÜFEN”

Open **Hilfe & Status** and use **macOS-Zugriff**. Enable ScrollFix on the macOS permission page, then return to the app. On newer macOS versions that page may be named **Device Control and Data Access**. If access is already granted, choose **Freigabe prüfen** in ScrollFix.

If macOS shows an older ScrollFix entry that no longer works after rebuilding, remove that entry, add the current `ScrollFix.app`, and grant access again. Keep the app in a stable path before enabling launch at login.

## The filter runs, but a device still scrolls the wrong way

1. Set macOS **Natural scrolling** to **on** under **System Settings → Trackpad → Scroll & Zoom**. This is the safer trackpad baseline: a gesture that loses its source classification then stays natural instead of switching to the classic direction.
2. Pause ScrollFix, scroll once with each device, then re-enable it and compare. Recognized streams should match the [setup and device limits](../README.md#faq).
3. Quit other tools that modify scrolling and try again.
4. If the problem is limited to one mouse, report its exact model, connection type, macOS version, whether it has a free-spin or high-resolution mode, and which applications show the problem. Do not post private input logs.

The classifier uses Quartz scroll phases and separate direct/momentum state. Some mouse drivers and remote desktop apps can bypass or alter those signals. With macOS Natural scrolling **off**, a tap reset during a trackpad gesture can change the output direction: the continued gesture becomes **Unklar** and is left unchanged. A phase-free pixel event within a recognized trackpad gesture now keeps that gesture's direction; an unrelated phase-free pixel event remains **Unklar**. A high-resolution mouse wheel interleaved during the active trackpad gesture may therefore follow the trackpad direction. **Mausrad: Bereit** means the event tap is running; it cannot validate your physical device automatically. **Hilfe & Status** shows access and filter state; detailed source traces are available only in QA builds.

## Middle-click autoscroll does not start

Enable **Autoscroll** in ScrollFix. It has its own **Mittelklick-Filter** status. If macOS asks for access to post events, grant it and choose **Freigabe prüfen**. A completed middle click on ordinary content starts autoscroll; moving the pointer beyond the marker's dead zone begins movement. Another mouse-button press stops it.

Recognized links and controls keep their native middle-click actions. Try an empty area in a standard browser page; links should open in a new tab according to the browser's preferences. Apps or canvas pages that omit Accessibility roles, very deep trees and slow AX responses pass through natively, so autoscroll may not start there. A modified middle click also stays native. ScrollFix does not distinguish a physical middle click from a synthetic one reliably.

## The settings window disappeared

ScrollFix also lives in the menu bar. Click its arrow icon and choose **Einstellungen**. The app can keep working with its window closed. **Beenden** in the menu stops the app.

## Launch at login does not work

Move the built app to its permanent location, start that copy, then enable **Bei Anmeldung starten**. macOS may require approval under **System Settings → General → Login Items & Extensions**. ScrollFix uses Apple's [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice) for this setting.

## Remove ScrollFix

Turn off **Bei Anmeldung starten**, choose **Beenden**, remove the app bundle, and revoke its macOS permission under Privacy & Security if desired. ScrollFix does not install a kernel extension, daemon, network service, or separate helper app.

## Shift+Home/End does not select the Terminal input

Use **Feineinstellungen → Terminal einrichten**. Open a new local zsh Terminal window after setup. A running shell does not reload its startup file automatically. This selects the input line, not previous terminal output; custom startup locations and remote shells need separate integration. See [Terminal setup](TERMINAL.md). If you remove ScrollFix, also remove its managed shell section as described there.
