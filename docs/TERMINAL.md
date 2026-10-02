# Windows-style Home/End and terminal input selection

In recognized text fields, **Home/End** move to the current line's start/end.
**Ctrl+Home/End** move to the document boundaries. **Shift** extends selection.
Use **Home/End in einzelnen Apps ausschalten → App hinzufügen …** to select apps that should keep their usual Home/End behavior. Unknown or secure input stays native by default. This is not a global Ctrl/Cmd swap.

## Set up Terminal from ScrollFix

1. Open ScrollFix's **Einstellungen → Feineinstellungen**.
2. Keep **Home / End wie Windows** enabled.
3. Click **Terminal einrichten** and confirm the explanation in the app.
4. Open a new local Terminal window. Type `alpha beta` without pressing Return and try **Shift+Home**, then **Shift+End**.

No developer tools or copied commands are needed for setup in a packaged app.
ScrollFix ships the module inside its app bundle and copies it to the current
user's `~/Library/Application Support/ScrollFix/terminal-selection.zsh`.
The installed module survives moving or updating the app. Setup adds one marked
section to `~/.zshrc` and stores an exact private backup beside the module.
Repeated setup does not duplicate the section or overwrite existing preferences.
Until setup succeeds, Shift navigation stays native.

The module supports local **zsh**, in the emacs keymap and vi insert mode. It
marks the current input line through zsh's line editor. It does not select old
terminal output or implement Windows clipboard shortcuts. Existing windows
need a new shell. Remote shells, Bash, tmux/screen and full-screen terminal
programs are not covered by this setup. Custom startup locations, symbolic
links and unexpected managed sections are refused rather than overwritten.
The **Home / End wie Windows** switch controls navigation and Shift selection together. Terminal compatibility choices are not exposed in the normal interface.

## Remove the shell integration

Turn off **Home / End wie Windows** first. Remove only the section
between `# BEGIN ScrollFix terminal selection` and
`# END ScrollFix terminal selection` from `~/.zshrc`, and remove the installed
`terminal-selection.zsh` file if desired. Keep any backups you still need.
If your startup file has changed since setup, preserve those newer changes;
restoring the whole backup would also undo them.

## Distribution

The production bundle includes the shell module and terminal app configuration;
it has no dependency on the maintainer's checkout or home directory. Build a
Universal app with `SCROLLFIX_BUILD_ARCHITECTURES=universal ./scripts/build-app.sh`.
Developer ID signing and notarization are separate release requirements.
Offline tests and the maintainer's real-device checks do not establish universal
application or macOS compatibility.
