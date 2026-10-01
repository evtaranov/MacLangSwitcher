# MacLangSwitcher

A tiny macOS menu bar app that switches the keyboard input source with **⌘ Cmd + ⇧ Shift**, Windows-style.

The menu bar shows the current input language (`EN`, `RU`, …).

## Features

- Press and release **⌘⇧** to switch to the next enabled input source.
- Regular shortcuts like ⌘⇧Z or ⌘⇧4 still work: if you press any other key or click while ⌘⇧ is held, the input source doesn't change.
- Menu bar indicator for the current language. It updates no matter how the input source changes.
- Menu with:
  - every enabled input source, so you can pick one manually;
  - a toggle to turn ⌘⇧ switching on or off;
  - Launch at Login;
  - Quit.
- No Dock icon, no dependencies, a single Swift file.

## Requirements

- macOS 13 Ventura or later
- Xcode Command Line Tools (`xcode-select --install`)

## Build & install

```sh
./build.sh           # builds build/LangSwitch.app
./build.sh install   # builds, copies to /Applications and launches
```

## Permissions

The app has to see global key events, so it needs **Accessibility** access. On first launch macOS asks for it. You can also grant it in
**System Settings → Privacy & Security → Accessibility**. The app picks up the permission automatically, so you don't need to restart it. Until access is granted, a ⚠︎ appears next to the language in the menu bar.

> The build is ad-hoc signed, so macOS treats every rebuild as a new app. After rebuilding, remove the old LangSwitch entry from the Accessibility list and add it again.

If ⌘⇧ conflicts with a system shortcut, disable that shortcut in
**System Settings → Keyboard → Keyboard Shortcuts → Input Sources**.

## How it works

- A listen-only `CGEventTap` watches modifier changes, key presses and mouse clicks.
- When ⌘ and ⇧ are both released with nothing pressed in between, the app picks the next source from `TISCreateInputSourceList` and selects it with `TISSelectInputSource`.
