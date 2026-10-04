# ScrollFix — Mausrad wie unter Windows, auf deinem Mac

**Maus-Scrollrichtung auf dem Mac ändern. Trackpad natürlich lassen. Mit dem Mausrad scrollen oder Links in einem neuen Tab öffnen.**

ScrollFix ist eine Open-Source-App für die macOS-Menüleiste. Sie richtet sich an alle, die das Mausverhalten von Windows bevorzugen. macOS verwendet dieselbe Einstellung für Maus und Trackpad. ScrollFix korrigiert erkannte Mausradbewegungen getrennt und bewegt die Seite standardmäßig sofort.

[Installationsanleitung](INSTALL.md) · [Selbst bauen](#bauen-und-installieren) · [English](../README.md) · [Probleme lösen](TROUBLESHOOTING.md) · [Datenschutz](PRIVACY.md) · [ScrollFix unterstützen](https://ko-fi.com/eshok93)

### Hilf mit, ScrollFix wie eine normale Mac-App installierbar zu machen

> **Gemeinsames Ziel: 250 €** — für einen signierten Mac-Download und weitere Verbesserungen.
>
> Dein Beitrag hilft, Apples Entwickler-Mitgliedschaft, Zahlungsgebühren und die weitere Arbeit an ScrollFix zu finanzieren. Mit der Mitgliedschaft kann ich die App signieren und von Apple auf bekannte Schadsoftware prüfen lassen.
>
> **Jeder einmalige Beitrag hilft.** Wähle auf Ko-fi 3 €, 10 €, 25 € oder einen eigenen Betrag.
>
> [![ScrollFix einmalig auf Ko-fi unterstützen](support/tip-button.de.svg)](https://ko-fi.com/eshok93)
>
> **ScrollFix bleibt kostenlos und Open Source.** Ein Beitrag ist freiwillig. Auch Teilen oder das Melden eines Fehlers hilft.

![ScrollFix auf dem Mac: natürliches Trackpad, Windows-Mausrad, Mittelklick-Scrollen und Direkt-Modus](screenshots/scrollfix-current.png)

## Was die App kann

- **Maus und Trackpad getrennt scrollen:** Trackpad natürlich, Mausrad klassisch.
- **Mausrad wie unter Windows:** Jeder erkannte Radschritt bewegt die Seite sofort. Die Strecke lässt sich anpassen.
- **Mittelklick-Scrollen:** Auf eine freie Fläche klicken, den Zeiger bewegen und zum Stoppen erneut klicken.
- **Links per Mittelklick öffnen:** Erkannte Links behalten den ursprünglichen Klick. Der Browser kann sie in einem neuen Tab öffnen.
- **Bei Anmeldung starten:** Mausrad, Mittelklick-Scrollen und Autostart sind bei der ersten Einrichtung aktiviert.
- **Home/End wie Windows:** Zeilenanfang/-ende und Auswahl mit Shift in erkannten Textfeldern; Ctrl springt im Dokument.
- **Terminal-Eingabe markieren:** Lokale zsh direkt in der App einrichten und Shift+Home/End in neuen Fenstern nutzen.
- **Lokal arbeiten:** Kein Konto, keine Analyse-Software und keine Netzwerkkommunikation in der App.

ScrollFix unterstützt außerdem Home/End und die optionale Auswahl der lokalen zsh-Eingabezeile. Ein globaler Ctrl/Cmd-Tausch, App-Zoom per Ctrl+Mausrad, Windows-Desktop-Kürzel und Änderungen der Displayqualität sind noch nicht enthalten. [Einrichtung und Grenzen](TERMINAL.md).

## Download und Installation

**Aktuelle Version: 0.3.2.** Der Quellcode ist aktualisiert; eine verifizierte DMG ist noch nicht veröffentlicht. Mit dem geplanten Download geht es wie bei einer normalen Mac-App: DMG öffnen, ScrollFix nach Programme ziehen, dort öffnen und den macOS-Zugriff erlauben. Dafür brauchst du kein Xcode und keine Terminal-Befehle. [Einfache Installationsanleitung](INSTALL.md).

Für die Veröffentlichung fehlen noch Apples Developer-ID-Zertifikat und Notarisierung. Die alte Preview enthält die aktuellen Funktionen nicht.

## Bauen und installieren

Die aktuellen Funktionen sind im Quellcode verfügbar. **Die alte [Preview v0.1.0](https://github.com/eShok93/ScrollFix/releases/tag/v0.1.0) enthält sie nicht.** Sie ist lokal signiert, nicht notarisiert und stammt aus der Zeit vor den Signaturkorrekturen. Ein neuer verifizierter Binärdownload ist noch nicht verfügbar.

Du brauchst **macOS 13 oder neuer**, **Swift 6** und das macOS SDK aus Xcode oder den Command Line Tools. Der Standard-Build passt zur Architektur deines Macs. Mit `SCROLLFIX_BUILD_ARCHITECTURES=universal` baust du für Apple Silicon und Intel; die alte Preview unterstützt nur Apple Silicon.

```sh
git clone https://github.com/eShok93/ScrollFix.git
cd ScrollFix
./scripts/build-app.sh
```

Verschiebe `build/ScrollFix.app` nach `/Applications` und öffne sie dort. Lass sie für den Autostart an diesem Ort. Der Build wird ad hoc signiert und nicht notarisiert. Nach einem Neubau musst du die macOS-Freigabe möglicherweise erneuern. Gatekeeper nicht global ausschalten.

### Erste Einrichtung

1. Aktiviere **Natürliches Scrollen** in den macOS-Trackpad-Einstellungen.
2. Erlaube ScrollFix unter **Systemeinstellungen → Datenschutz & Sicherheit → Bedienungshilfen**. Auf neueren macOS-Versionen heißt der Bereich gegebenenfalls **Gerätesteuerung und Datenzugriff**. **Zugriff erlauben** in der App öffnet die passende Seite.
3. Kehre zurück und prüfe **AKTIV**. Teste Trackpad und Mausrad einmal.

**Direkt (Windows)** ist vorausgewählt. **Mausrad**, **Mittelklick-Scrollen** und **Bei Anmeldung starten** sind standardmäßig an; gespeicherte Entscheidungen bleiben erhalten. Für Mittelklick-Scrollen oder weiche Bewegung kann macOS zusätzlich erlauben müssen, dass die App Scrollbewegungen auslöst. Gemeint ist Bewegung in deinen Apps, keine Datenübertragung an einen Server.

### Terminal-Auswahl

Klicke unter **Feineinstellungen** auf **Terminal einrichten** und bestätige den Dialog. ScrollFix sichert die Shell-Konfiguration und installiert das mitgelieferte Modul in deinem Benutzerordner. Danach ein neues lokales zsh-Terminal öffnen. Keine Befehle kopieren. Besondere Shell-Konfigurationen bleiben unverändert; [Einrichtung und Grenzen](TERMINAL.md).

## Mausrad einstellen

| Einstellung | Verhalten |
| --- | --- |
| **macOS** | Behält die native Scrollstrecke bei; ScrollFix korrigiert die Richtung. |
| **Direkt (Windows)** | Bewegt die Seite sofort, mit einstellbarer Mindeststrecke für kleine Radschritte. Standard. |
| **Weich** | Verteilt die Bewegung über mehrere Bilder, mit weichem Anlauf und kurzem Nachlauf. |

**Feineinstellungen** sind standardmäßig aufgeklappt. Mit **Scrollstrecke pro Radschritt** passt du die Strecke an. Die Einstellungen gelten für erkannte vertikale Zeilenimpulse. Trackpad-Gesten, Pixel-Mausradbewegungen und unklare Eingaben umgehen diese Stufe. Direkt entspricht dem unmittelbaren Windows-Gefühl, nicht einer exakten Drei-Zeilen-Einstellung in jeder App.

## Häufige Fragen

### Kann ich nur die Scrollrichtung der Maus ändern?

Für erkannte Mausradbewegungen ja. Lass **Natürliches Scrollen** in macOS an und aktiviere **Mausrad** in ScrollFix. Die App liest die Systemeinstellung, verändert sie aber nicht.

### Öffnet ein Klick auf das Mausrad einen neuen Tab?

Auf erkannten Links reicht ScrollFix den ursprünglichen Mittelklick an den Browser weiter. Dieser entscheidet, wie er den Link öffnet. Auf normalen Inhalten startet der Klick Autoscroll. Der Mittelklick-Filter läuft unabhängig von der Oberfläche und kann unterbrochene Klicks wieder aufnehmen. Unklare Ziele und Bedienelemente behalten ihr natives Verhalten; unvollständige Bedienungshilfen können die Erkennung begrenzen.

### Funktioniert das mit einem Logitech-Freilaufrad?

Dichte, erkannte Zeilenimpulse erhalten im weichen Modus eine kürzere Antwort; Gegensteuern bricht den bisherigen Nachlauf ab. ScrollFix erkennt weder das Logitech-Modell noch den mechanischen Freilaufmodus. Pixelbasierte Treiber-Ausgaben können die Verarbeitung umgehen. Teste dein Gerät in den Apps, die du verwendest.

### Was passiert mit meinen Eingaben?

Die Verarbeitung läuft auf deinem Mac. Home/End verarbeitet Tastencodes und Zusatztasten, speichert aber keine getippten Texte. Die optionale Terminal-Einrichtung liest und erhält deine lokale Shell-Konfiguration. Sie überträgt keine Ereignisse übers Netzwerk. Der genaue Umfang steht im [Datenschutz-Dokument](PRIVACY.md).

### Gibt es Grenzen bei der Geräteerkennung?

Ja. Scrollphasen liefern keine eindeutige Gerätekennung pro Ereignis. Unbekannte Eingaben bleiben unverändert; präzise Mäuse, besondere Treiber, Remote-Desktops und schnelle Gerätewechsel können mehrdeutig sein. Deshalb Natürliches Scrollen anlassen und beide Geräte testen. Die Richtungskorrektur betrifft nur die vertikale Achse. Andere Scroll-Apps können stören.

## Qualität und Entwicklung

Swift und SwiftUI, ohne externe Paketabhängigkeiten. Automatische Prüfungen helfen gegen wiederkehrende Fehler; zusätzlich sind echte Tests mit Maus, Trackpad und Tastatur nötig. Als Nutzer musst du keine Tests installieren oder ausführen. [Details für Entwickler](../CONTRIBUTING.md#verification).

[Technik](HOW-IT-WORKS.md) · [Mitwirken](../CONTRIBUTING.md) · [Release-Anforderungen](RELEASING.md)

Lokale Builds sind Entwicklungsartefakte. Ein öffentlicher Binärrelease braucht Developer ID, Apple-Notarisierung und die dokumentierte Release-Prüfung. Die Produktionsversion behält keine QA-Ereignisverläufe. Einige flüchtige Zeitwerte liegen im Arbeitsspeicher; siehe [Datenschutz](PRIVACY.md).

## Lizenz

[Apache 2.0](../LICENSE). Lizenzhinweise stehen in [NOTICE](../NOTICE), technische Referenzen in [Herkunft](PROVENANCE.md).
