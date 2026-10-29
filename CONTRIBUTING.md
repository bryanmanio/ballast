# Contributing to Ballast

Thanks for helping. Bug reports, fixes and small features are all welcome. For anything larger, open an issue first so we can agree on the approach before you put time into it.

By taking part you agree to follow the [code of conduct](CODE_OF_CONDUCT.md). Security problems go through [SECURITY.md](SECURITY.md), not public issues.

## Reporting bugs

Use the bug report template. The most helpful details are your Ballast, macOS and DSM versions, what you expected, and what happened instead. If the problem is with one container, include its compose file or labels with anything private removed.

## Setting up

You need a Mac running macOS 26 or later and a recent Xcode.

```sh
git clone https://github.com/bryanmanio/ballast.git
cd ballast
open Ballast/Ballast.xcodeproj
```

You don't need a NAS to work on most of the app. This loads sample data instead:

```sh
defaults write com.mediumrare.ballast BallastUseFixtures -bool YES
```

Set it back to `NO` to connect to a real NAS again.

## Tests

```sh
./scripts/test.sh
```

The pure logic lives in `Ballast/Ballast/Core` and is tested through SwiftPM, so `swift test` works without Xcode. New logic in `Core` should come with tests in `Tests/BallastCoreTests`. Sample agent output for those tests goes in `Tests/BallastCoreTests/Fixtures`.

## Changes to the NAS agent

`nas/ballast-agent` runs as root through a passwordless sudo rule, so it's held to a stricter standard than the rest of the code:

- It must only accept a fixed set of subcommands. Don't add anything that passes arbitrary arguments to Docker, and don't add `exec`, `run`, `rm` or similar.
- Any container name or ID it receives has to be checked against the live container list before Docker sees it.
- Keep it POSIX `sh`, like the rest of the scripts in `nas/`.
- Its output fields are a protocol. Only append new ones, bump `PROTOCOL_VERSION` when you do, and update the app to match.

Explain in the pull request why the change is safe. Test it on a real Synology if you can, and say which DSM version you used.

## Pull requests

- Branch from `main` and keep each pull request to one change.
- Run `./scripts/test.sh` and build the app in Xcode before you open it.
- Add screenshots for anything visible in the UI.
- Update the README if you change setup steps, labels or shortcuts.
- Match the style of the code around your change. Comments should explain why something is done, not what the line does.

Don't bump the version number or edit release scripts unless that's the point of the change. Releases are cut separately.

## License

Ballast is licensed under the GPL-3.0. Your contributions are released under the same license.
