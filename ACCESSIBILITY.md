# Accessibility

Ballast should work for people who use VoiceOver, the keyboard, or reduced motion. If something gets in your way, that's a bug, and I want to hear about it.

## What's supported

Ballast runs on macOS 26 and later and is built with SwiftUI, so it picks up the system's accessibility settings.

- Container status has a text label for VoiceOver, so it isn't conveyed by colour alone. The menu bar icon has a label too.
- With Reduce Motion on, the refresh animation and the onboarding transitions are replaced with simple changes, and the setup videos don't play automatically.
- Icon-only buttons have labels and tooltips.
- ⌥⌘B opens the menu from anywhere. Inside it, ⌘F filters, ⌘R refreshes and ⌘, opens Settings. You can change the global shortcut in Settings.
- Every command in the setup window can be copied with one click.

## Known limitations

- Start, stop and restart buttons only appear when you hover over a row. The same actions are in the row's right-click menu.
- Setup involves running commands in Terminal and on the NAS over SSH. The setup window explains each step, but it can't do them for you.

## Reporting a problem

Open an issue using the [accessibility template](https://github.com/bryanmanio/ballast/issues/new?template=accessibility.yml). Say which assistive technology and macOS version you're using and what you were trying to do. Accessibility problems are treated as bugs.
