# Install ScrollFix on your Mac

ScrollFix is a Mac app. A `.dmg` is the download container; `ScrollFix.app` inside it is the application. You do not need an `.exe` on macOS.

## Download status

**Version 0.3.2 is currently available as source code. A verified, ready-to-install DMG is not published yet.** The old v0.1.0 download does not contain the current mouse, middle-click or keyboard fixes. If you are unfamiliar with building software, wait for the signed DMG rather than installing that old preview.

A public DMG requires an Apple Developer ID signature and notarization. These are not available for this version yet. A locally prepared DMG is not a verified public release. See [release requirements](RELEASING.md).

## When the verified DMG is available

1. Download the DMG from this repository's GitHub Releases page.
2. Double-click the DMG, then drag **ScrollFix** onto **Applications / Programme**.
3. Eject the disk image. Open **ScrollFix** from **Applications / Programme**, not from the disk image.
4. In ScrollFix, click **Zugriff erlauben**. In macOS Privacy & Security, enable **ScrollFix** under **Accessibility / Bedienungshilfen**. Some macOS versions call this **Device Control and Data Access / Gerätesteuerung und Datenzugriff**. Confirm any authentication yourself.
5. Return to ScrollFix. It should say **AKTIV**. Leave **Natural scrolling / Natürliches Scrollen** on in macOS Trackpad settings, then test both devices.

No account or command-line setup is needed with a published DMG. Mouse correction, middle-click scrolling, Home/End navigation and login startup are on by default. Existing preferences are preserved.

### Optional: Home/End selection in Terminal

Under **Feineinstellungen**, click **Terminal einrichten** and confirm. Then open a new local zsh Terminal window. This selects text in your current input line with Shift+Home/End; it does not select terminal output. [Details and removal](TERMINAL.md).

### Updating an older installation

Quit ScrollFix first, then replace its copy in Applications with the new app. Keep only one running copy. If the app says **Zugriff prüfen** despite an enabled macOS switch, remove only the old ScrollFix entry with the minus button, add the current copy from Applications with the plus button, and enable it again. Do not reset other apps' permissions.

### Removing ScrollFix

Turn off **Bei Anmeldung starten**, quit ScrollFix and move it from Applications to the Trash. Remove only ScrollFix from macOS permissions if desired. The optional Terminal integration is separate; follow its [removal instructions](TERMINAL.md).

## Auf Deutsch

**Für 0.3.2 gibt es derzeit noch keinen verifizierten DMG-Download.** Der Quellcode ist aktuell; die alte v0.1.0-Preview enthält die neuen Funktionen nicht. Für einen normalen Download fehlen noch Apples Developer-ID-Signatur und Notarisierung.

Sobald die signierte DMG veröffentlicht ist:

1. DMG herunterladen und doppelklicken.
2. ScrollFix auf **Programme** ziehen.
3. Das Disk-Image auswerfen und ScrollFix aus **Programme** öffnen.
4. Über **Zugriff erlauben** nur ScrollFix in den macOS-Berechtigungen aktivieren.
5. In der App **AKTIV** prüfen. Natürliches Scrollen fürs Trackpad bleibt in macOS an.

Ein Konto, Xcode und Terminal-Befehle brauchst du dafür nicht. Die optionale Terminal-Auswahl richtest du mit **Terminal einrichten** in der App ein.
