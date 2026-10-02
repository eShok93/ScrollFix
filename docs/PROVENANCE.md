# Technical references

ScrollFix is an independent Swift/SwiftUI implementation with its own UI, event pipeline, motion model and app assets. The following projects were studied as technical references. No source files, assets or dependencies from them are included in this repository.

| Reference | Subject studied | License of the reference |
| --- | --- | --- |
| [Scroll Reverser](https://github.com/pilotmoon/Scroll-Reverser), Nick Moore and contributors | Scroll-source classification and event taps | Apache 2.0 |
| [WinMice](https://github.com/anibalribeiro/WinMice), Anibal Ribeiro | Middle-click autoscroll and native click handling | MIT |
| [Mos](https://github.com/Caldis/Mos), Caldis and contributors | Minimum wheel distance and smooth response | CC BY-NC 4.0 |

WinMice reference: `78abc2f183cf3eaa420d1b8248d2cbab184266af`. Mos reference: `8a2fd112e2af444c37ca5f65f42e9bd19c08a5c2`. Their licenses describe those projects; ScrollFix is distributed under its own [Apache 2.0 license](../LICENSE). Existing notices are retained in [NOTICE](../NOTICE).

ScrollFix uses documented public Apple APIs. Its native-link routing preserves the original click after a bounded AX role/parent lookup; it does not replay clicks. Its wheel movement uses elapsed time and its own worker-owned pipeline. See [How it works](HOW-IT-WORKS.md) for the implementation and limits.
