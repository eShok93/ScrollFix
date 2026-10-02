# How ScrollFix works

macOS presents “Natural scrolling” in both Mouse and Trackpad settings, but both controls use the shared `com.apple.swipescrolldirection` preference. ScrollFix reads that preference; it does not write it.

| macOS baseline | Event selected for reversal | Result |
| --- | --- | --- |
| Natural on | Phase-free discrete line ticks | Natural trackpad, likely wheel line ticks classic; standalone ambiguous pixel input unchanged |
| Natural off | Recognized trackpad input inferred from scroll phases | Recognized trackpad streams natural, wheel classic; unknown streams unchanged |

When **Mausrad** is off, the direction and wheel-feel stage are stopped and both devices use the macOS baseline. When it is on, a Quartz session event tap receives scroll-wheel events. ScrollFix changes the sign of vertical scroll deltas in the selected stream and passes the other stream through. It updates its direction policy if the macOS preference changes while the app is running.

## Device classification

Phase-free line ticks are treated as likely mouse-wheel events. A continuous phase-free event during an active, previously recognized trackpad gesture follows that trackpad; without that context it is ambiguous and passes through unchanged because the `isContinuous` flag describes pixel-based deltas, not a physical device. This protects an in-progress trackpad gesture when macOS omits a phase. A high-resolution pixel wheel interleaved during that gesture may also follow the trackpad direction, while an unrelated high-resolution wheel remains at the macOS direction. With Natural off, a standalone ambiguous trackpad event keeps the classic direction. A `mayBegin` scroll phase is trackpad evidence until its matching terminal phase or a tap reset; a phased stream without that signal is ambiguous and passes through unchanged. The classifier keeps direct and momentum owners separately, so a phase-free event during trackpad momentum does not take over the momentum stream. Pending momentum ownership expires after a gap; direct gesture ownership clears when the gesture ends, the tap stops, or the Mac wakes. Without a documented per-event device ID, the classifier cannot guarantee the source of phase-free input.

The classification is heuristic. Quartz does not provide a documented mouse-versus-trackpad device ID in these fields. A missing phase, rapid switch, unusual driver, Magic Mouse touch input, or remote desktop can produce an unknown or wrong result. Unknown events pass through unchanged. Only the vertical axis is transformed. The app does not claim device-level certainty from the operating system.

## Mouse wheel feel

The direction rewrite preserves native wheel magnitudes. An additional stage offers three user-facing modes: **macOS** retains that distance; **Direkt (Windows)** applies a minimum distance to small vertical line impulses immediately; **Weich** consumes the eligible original impulse and emits paced pixel frames with a soft onset and decay. The legacy tactile implementation remains internal for regression coverage; saved tactile preferences migrate to Direct. The default minimum is 48 pixel units and can be adjusted from 16 to 128. Larger native deltas keep their distance. This is not a physical notch counter or a guarantee of three text lines in every application.

The wheel stage runs on the dedicated event-tap thread, with no CGEvent crossing into the UI. Pixel/trackpad/unknown input, phases, momentum, modifiers and horizontal input bypass this stage. Synthetic wheel frames have their own recursion marker. Clicks, pointer/modifier/context changes, device policy changes and tap/session resets cancel pending movement. Isolated Weich impulses use 180-ms and 60-ms time constants. Four positive inter-input gaps of at most 35 ms identify a dense line-wheel sequence; after that, ordinary impulses retain their native magnitude without repeated minimum amplification. A gap of 150 ms or an existing cancellation resets cadence. This timing heuristic cannot identify a physical freewheel mode.

Dense sequences and counter-scroll use a 60-/20-ms response. A profile transition preserves current velocity, and an opposite impulse discards all old motion before integration or output. The first counter impulse retains the minimum distance so steering can start visibly. Responsive software tails stop after 220 ms from the last input by discarding residual movement, without a final flush; full distance conservation applies only to isolated soft responses. New same-direction gestures return to the soft profile; an opposite gesture while an old tail is active still starts fast. Fractional distance and backlog remain bounded.

On macOS 14 and later, Weich uses a prewarmed NSScreen display link for the screen containing the event position. The macOS 13 compatibility path uses CVDisplayLink with coalesced delivery to the same worker run loop; that path is compiled but not runtime-tested on macOS 13. Screen changes refresh the links. A stopped clock is detected independently of new wheel input, and its old tail is discarded before timer fallback. The timer targets 1/120 second for the legacy tactile implementation and fallback; display links, health checks and timers are parked while idle. QA reports the actual clock kind. Event sources and clocks are prepared after positive posting access. Deferred frames receive a fresh monotonic timestamp. Before distributing a binary, verify physical mouse/trackpad handoff, wheel reversal, reconnect, sleep/wake and middle-click targets on supported macOS versions. Offline tests alone do not prove hardware compatibility.

## Optional autoscroll

When **Autoscroll** is enabled, a separate session tap receives middle-button down/up/drag and other button presses. A completed middle click on ordinary content starts or stops a pointer anchor. Other mouse-button presses stop scrolling and still reach their target. A 16-ms main-queue timer converts pointer distance from the anchor into bounded pixel deltas, with a radial dead zone and fractional carry. It posts synthetic scroll events tagged only to prevent ScrollFix's direction tap from reversing them again. That tag is not an authentication mechanism.

At the first middle down, a public Accessibility hit-test uses that event's global top-left location. A walk of at most 24 roles searches ancestors for links and native controls, reaching a web-area or window boundary before capturing ordinary content. Content containers inside a link are traversed. Missing attributes, failed queries and exhausted depth/time return a native decision. AX messaging uses a 6-ms per-call timeout and a 30-ms best-effort total deadline; OS scheduling can exceed these limits. The button tap, routing state, AX lookup and lost-release watchdog run on a dedicated thread, independent of SwiftUI. Generation-tagged, ordered value snapshots deliver start/stop commands to the main actor. Only roles, parents and the hit element's PID for an own-overlay check are read. There are no URL, text or value reads, hover scans or AX actions. [Apple hit-testing](https://developer.apple.com/documentation/applicationservices/1462077-axuielementcopyelementatposition), [messaging timeout](https://developer.apple.com/documentation/applicationservices/1459345-axuielementsetmessagingtimeout).

The chosen native/captured route holds through duplicate downs, drags and the matching up even when the pointer moves. A recognized link stops active autoscroll and receives the original down/up so the browser decides how to open it. Controls, modified clicks, own UI/overlay hits and uncertain targets also pass through. Captured pairs drain on stop; the watchdog suppresses a late consumed up and drag while the tap remains available. Native pairs survive tap removal/restart; if their up occurred with the tap absent, at most the next full click passes natively. There is no synthetic click or replay. Browser preferences, custom canvas content, incomplete AX trees and mouse macros can limit native link behavior. Autoscroll requests Post Event permission only when enabled. No button or scroll history is saved.

## Status model

- **AUS**: both features are disabled and both event taps are stopped.
- **AKTIV**: every enabled feature has its running event tap, and Weich has posting access when requested.
- **PRÜFEN**: an enabled feature is missing a running tap or required posting access. The app shows a combined permission or retry action.

The running event tap is used as the status signal because macOS permission preflight values can lag after a permission change. A running tap does not prove how a particular physical device is classified; users should scroll once with both devices. QA builds show the last **inferred** source and reason in memory. Production shows feature readiness and macOS access, without event traces.

## Project map

| Path | Purpose |
| --- | --- |
| `Sources/ScrollFix/App.swift` | SwiftUI menu, settings, system-preference reading, permission and login-item status |
| `Sources/ScrollFix/ScrollEventEngine.swift` | MainActor facade and ordered value snapshots |
| `Sources/ScrollFix/ScrollEventTapWorker.swift` | Worker-owned event tap, wheel clocks and lifecycle |
| `Sources/ScrollFix/ScrollWheelRewriter.swift` | Vertical direction changes and stream state |
| `Sources/ScrollFix/MouseWheelPipeline.swift` | Eligible line-wheel normalization and pixel frames |
| `Sources/ScrollFix/MouseWheelMotion.swift` | Minimum-distance normalization and tactile motion |
| `Sources/ScrollFix/SmoothWheelMotion.swift` | Continuous soft onset and decay |
| `Sources/ScrollFix/WheelInputCadence.swift` | Timing heuristic for validated dense line-wheel input |
| `Sources/ScrollFix/MouseWheelFrameClock.swift` | Per-screen display pulses and clock health |
| `Sources/ScrollFix/ScrollSourceClassifier.swift` | Scroll-phase source inference and momentum state |
| `Sources/ScrollFix/AutoScrollController.swift` | Main-actor autoscroll UI and synthetic scroll lifecycle |
| `Sources/ScrollFix/MiddleClickTapWorker.swift` | Independent middle-button tap, routing, AX lookup and lost-release recovery |
| `Sources/ScrollFix/MiddleClickRouting.swift` | Complete native/captured button-pair decisions |
| `Sources/ScrollFix/MiddleClickTargetResolver.swift` | Bounded public AX role/parent lookup for native links and controls |
| `Sources/ScrollFix/AutoScrollPhysics.swift` | Pointer-to-scroll math |
| `Resources/ScrollFixLogo.svg` and `.png` | Original app mark and its rasterized build asset |
| `scripts/render-icon.swift` | Regenerates the PNG from the SVG |
| `scripts/build-app.sh` | Local app bundle, icon, and ad hoc signing |

Apple references: [Quartz event taps](https://developer.apple.com/documentation/coregraphics/cgevent/tapcreate(tap:place:options:eventsofinterest:callback:userinfo:)), [scroll phases](https://developer.apple.com/documentation/appkit/nsevent/phase-swift.property), and [login items with SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice).
