# Troubleshooting

Start with the two device labels in ScrollFix. They show the expected effective direction, and **Details** shows the macOS baseline, permission, and filter status.

## The mouse already feels right with the fix off

That can be correct. With macOS “Natural scrolling” **off**, a mechanical wheel is already classic. The trackpad is then also classic. Turn on **Fix aktiv** if you want the trackpad natural while keeping the wheel classic. The app should show **Trackpad: Natürlich** and **Mausrad: Klassisch**.

## “Fix aktiv” is on, but the status says “PRÜFEN”

Open **Details** and use **macOS-Freigabe**. Enable ScrollFix on the macOS permission page, then return to the app. On newer macOS versions that page may be named **Device Control and Data Access**. If access is already granted, choose **Erneut prüfen** in ScrollFix.

If macOS shows an older ScrollFix entry that no longer works after rebuilding, remove that entry, add the current `ScrollFix.app`, and grant access again. Keep the app in a stable path before enabling launch at login.

## The filter runs, but a device still scrolls the wrong way

1. Check which direction macOS itself uses under **System Settings → Trackpad → Scroll & Zoom**.
2. Pause ScrollFix, scroll once with each device, then re-enable it and compare. The two states should match the [direction table](../README.md#what-changes).
3. Quit other tools that modify scrolling and try again.
4. If the problem is limited to one mouse, report its exact model, connection type, macOS version, whether it has a free-spin or high-resolution mode, and which applications show the problem. Do not post private input logs.

The classifier uses discrete wheel ticks and two-finger gesture timing. Some mouse drivers and remote desktop apps can bypass or alter that signal. **AKTIV** means the event tap is running; it cannot validate your physical device automatically.

## The settings window disappeared

ScrollFix also lives in the menu bar. Click its arrow icon and choose **Einstellungen**. The app can keep working with its window closed. **Beenden** in the menu stops the app.

## Launch at login does not work

Move the built app to its permanent location, start that copy, then enable **Bei Anmeldung starten**. macOS may require approval under **System Settings → General → Login Items & Extensions**. ScrollFix uses Apple's [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice) for this setting.

## Remove ScrollFix

Turn off **Bei Anmeldung starten**, choose **Beenden**, remove the app bundle, and revoke its macOS permission under Privacy & Security if desired. ScrollFix does not install a kernel extension, daemon, network service, or separate helper app.
