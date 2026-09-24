# Privacy and permissions

ScrollFix works locally. The repository contains no analytics SDK, network client, account system, or telemetry endpoint. It does not persist a history of scroll or gesture events.

To change scrolling across applications, the app creates a Quartz **session event tap**. The tap subscribes to scroll-wheel and gesture events, classifies their source, and optionally changes vertical deltas in memory. macOS grants this through a broad accessibility or device-control permission. The wording in System Settings describes what such a permission *could* allow, not a narrow permission limited to scrolling. Review the source before granting it.

The app stores only two user preferences through macOS mechanisms: whether **Fix aktiv** is on, and whether the main app is registered as a login item. It reads macOS's shared natural-scrolling preference but never changes it. It does not ask for administrator or root access.

Source: [App.swift](../Sources/ScrollFix/App.swift) and [ScrollEventEngine.swift](../Sources/ScrollFix/ScrollEventEngine.swift). Apple's [event-tap documentation](https://developer.apple.com/documentation/coregraphics/cgevent/tapcreate(tap:place:options:eventsofinterest:callback:userinfo:)) describes the underlying API.
