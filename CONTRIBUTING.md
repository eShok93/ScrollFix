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
- actual direction for each device, with Fix on and off;
- any other scroll utility or mouse driver in use.

Please avoid screenshots of other applications, private input logs, serial numbers, or account information. A screenshot of the ScrollFix window alone is usually enough.

## Code changes

Keep the event-tap callback small and local. Avoid disk or network work in the scroll path. If a change affects device classification, describe which hardware and event pattern it addresses. Update the direction table and limitations when behavior changes. Include source attribution when adapting external code or algorithms; see [Provenance](docs/PROVENANCE.md).

By contributing, you agree that your contribution is licensed under the repository's [Apache 2.0 license](LICENSE).
