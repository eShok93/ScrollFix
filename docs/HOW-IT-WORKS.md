# How ScrollFix works

macOS presents “Natural scrolling” in both Mouse and Trackpad settings, but both controls use the shared `com.apple.swipescrolldirection` preference. ScrollFix reads that preference; it does not write it.

| macOS baseline | Event selected for reversal | Result |
| --- | --- | --- |
| Natural on | Discrete mouse-wheel input | Natural trackpad, classic wheel |
| Natural off | Trackpad input inferred from two-finger gestures | Natural trackpad, classic wheel |

When **Fix aktiv** is off, the event tap is stopped and both devices use the macOS baseline. When it is on, a Quartz session event tap receives scroll-wheel and gesture events. ScrollFix changes the sign of vertical scroll deltas in the selected stream and passes the other stream through. It updates its mode if the macOS preference changes while the app is running.

## Device classification

Discrete, phase-free ticks are treated as mouse-wheel events. Continuous events alone are ambiguous: a high-resolution wheel can report them too. The filter therefore also watches gesture events for recent two-finger contact. It remembers the last identified source during momentum scrolling. This approach is informed by [Scroll Reverser](https://github.com/pilotmoon/Scroll-Reverser), which has a more mature classifier.

The classification is heuristic. Rapid changes between devices, unusual drivers, Magic Mouse touch input, and remote desktop software can produce a different result. Only the vertical axis is transformed. The app does not claim device-level certainty from the operating system.

## Status model

- **AUS**: the user disabled the fix; the event tap is stopped. The displayed device directions come from the macOS preference.
- **AKTIV / Bereit**: the event tap is running. The displayed device directions reflect the selected filter mode.
- **PRÜFEN**: the fix is enabled, but the event tap is not running. The app shows the permission link or a retry action.

The running event tap is used as the status signal because macOS permission preflight values can lag after a permission change. A running tap does not prove how a particular physical device is classified; users should scroll once with both devices.

## Project map

| Path | Purpose |
| --- | --- |
| `Sources/ScrollFix/App.swift` | SwiftUI menu, settings, system-preference reading, permission and login-item status |
| `Sources/ScrollFix/ScrollEventEngine.swift` | Event tap, gesture classification, vertical delta transformation |
| `Resources/ScrollFixLogo.svg` | Original app mark |
| `scripts/build-app.sh` | Local app bundle, icon, and ad hoc signing |

Apple references: [Quartz event taps](https://developer.apple.com/documentation/coregraphics/cgevent/tapcreate(tap:place:options:eventsofinterest:callback:userinfo:)) and [login items with SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice).
