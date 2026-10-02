# Contributing

Thanks for helping improve ScrollFix. Device classification is the hardest part, so concrete hardware reports are especially useful.

## Build locally

Use a Mac with Swift 6 and the macOS SDK. Run `./scripts/build-app.sh`, then open `build/ScrollFix.app`. Build and distribution folders are ignored by Git. The script creates a locally signed bundle; it does not make a notarized release.

## Report a problem

Open an issue with:

- macOS version and Mac model;
- mouse and trackpad models and connection types;
- the macOS “Natural scrolling” value;
- ScrollFix status and the direction shown for each device;
- actual direction for each device, with Mausrad on and off;
- any other scroll utility or mouse driver in use.

Please avoid screenshots of other applications, private input logs, serial numbers, or account information. A screenshot of the ScrollFix window alone is usually enough.

## Code changes

Keep the event-tap callback small and local. Avoid disk or network work in the scroll path. If a change affects device classification, describe which hardware and event pattern it addresses. Update the setup guidance and limitations when behavior changes. Include source attribution when adapting external code or algorithms; see [Provenance](docs/PROVENANCE.md).

Use `swift test --disable-sandbox` on a Mac with Swift 6 and XCTest available for offline regression checks. These tests check code paths, not physical hardware behavior. Test real middle-button behavior, rapid device handoffs, reconnect, and sleep/wake on hardware before making a release.

## Verification

The offline regression suite passed 259 tests on 3 October 2026. It covers numeric bounds, input routing, focus ownership, recovery, permission policy, settings migration and Terminal setup using temporary directories. Four isolated zsh PTY checks also passed. These are developer checks, not part of the installed app and not a requirement for users.

Physical acceptance covered mouse/trackpad behavior in the user's setup, middle-click links and autoscroll, MX Keys Shift+Home in TextEdit, and local Terminal.app/zsh input selection. This does not establish compatibility with every device, app, modifier combination or Intel Mac. Confirm affected real-input cases alongside automated checks before claiming a fix.

By contributing, you agree that your contribution is licensed under the repository's [Apache 2.0 license](LICENSE).
