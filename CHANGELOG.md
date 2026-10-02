# Changelog

## Unreleased

- Run the middle-click event tap, bounded Accessibility lookup and release recovery independently of the SwiftUI thread. Keep in-flight clicks through timeout recovery and preserve native links.
- Extend bounded link/control ancestry checks to 24 elements, and require sustained physical release before cleaning up a missing button-up.

- Enable launch at login, mouse-wheel correction in Direct mode, and middle-click autoscroll by default on first launch; preserve explicit saved choices.
- Preserve native browser behavior when a middle click targets a link, while keeping autoscroll on ordinary content.
- Keep detailed source, wheel and timing traces in QA builds; production shows user-facing system and permission status only.
- Remove the optional HiDPI text-clarity trial; keep ScrollFix focused on scrolling and the planned Windows-style workflow.
- Offer macOS, Direct (Windows), and Smooth wheel modes; migrate the legacy tactile preference to Direct and expand fine settings by default. Normalize recognized mouse-wheel line impulses; cancel the tail promptly on counter-scroll and input changes.
- Classify direct and momentum scroll streams separately using Quartz scroll phases.
- Rebuild or re-enable taps after sleep, screen wake, and session changes; clear stale source state.
- Reject overflowing synthetic scroll deltas before changing any event.
- Remove the identifier-only ad hoc signing requirement. Local rebuilds may need a new Accessibility grant; a Developer ID release still needs notarization.

## v0.1.0 — 2026-09-24

First public preview.

- Separate natural trackpad and classic mouse-wheel scrolling while leaving the macOS preference untouched.
- Automatic filter mode for either macOS natural-scrolling baseline.
- Two-finger gesture signal for distinguishing trackpads from continuous mouse wheels.
- Menu-bar controls, permission and filter status, and launch-at-login option.
- English and German setup documentation, troubleshooting, privacy notes, and screenshots.

**Known limits:** vertical scrolling only; unusual mouse drivers, Magic Mouse gestures, remote desktops, and rapid device switching may need further work. The Apple Silicon preview ZIP is ad hoc signed and is not notarized.
