# Provenance

ScrollFix is an independent SwiftUI application. Its event-tap design and the use of two-finger gesture events to distinguish a trackpad from a continuous mouse wheel were informed by [Scroll Reverser](https://github.com/pilotmoon/Scroll-Reverser) by Nick Moore and contributors. That project is licensed under Apache License 2.0; see our [NOTICE](../NOTICE) and [LICENSE](../LICENSE).

No source file from Scroll Reverser is included in this repository. ScrollFix has its own UI, model, filter lifecycle, build script, and vector icon. The classifier uses a short recent-touch window and remembers the previous device during momentum. These are behavioral ideas shared with the reference implementation; the precise limits are described in [How it works](HOW-IT-WORKS.md).

Apple's [Quartz event tap documentation](https://developer.apple.com/documentation/coregraphics/cgevent/tapcreate(tap:place:options:eventsofinterest:callback:userinfo:)) describes the underlying system API.
