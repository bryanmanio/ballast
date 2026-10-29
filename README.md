# Ballast

<img width="1375" height="916" alt="5c2d0b15-dea4-47fe-9de7-c2e917440db7" src="https://github.com/user-attachments/assets/a5ab41c9-fc47-4453-9ae6-72454c13fade" />

Ballast is a macOS menu bar app that lists the Docker containers on your Synology NAS, shows whether each one is up, and opens any of them in your browser when you click.

It connects over SSH with your existing key and `~/.ssh/config`, then runs a small script on the NAS that only reads from Docker. Nothing runs as a daemon, the Docker socket stays unexposed, and the app never stores credentials.

## Setup

The first time you open Ballast, a setup window walks you through these steps with every command ready to copy. You can come back to it later from **Set up Ballast…** in the menu.

1. **Enable SSH** on the NAS (Control Panel → Terminal & SNMP) with an account in the administrators group. A dedicated account works well, and you can deny it every application in DSM.
2. **Add a key** with no passphrase:
   ```sh
   ssh-keygen -t ed25519 -f ~/.ssh/id_ballast -C "ballast"
   ./nas/deploy-key.sh ballast-user@nas.local ~/.ssh/id_ballast.pub
   ```
   This edits `sshd_config`, so keep a second SSH session open while it runs.
3. **Install the agent:**
   ```sh
   ./nas/deploy.sh ballast-user@nas.local
   ```
   This installs a root-owned script that reads from Docker and can start, stop or restart a container, and lets that script, and only that script, run with sudo.
4. **Point the app at your NAS** under Settings → Connection and click **Test connection**.

DSM updates sometimes reset `sshd_config`; if Ballast stops connecting after one, run `deploy-key.sh` again.

## Features

- **Status** comes from Docker's own state plus each container's healthcheck.
- **Start, stop or restart** a container by hovering its row or right-clicking it.
- **Image updates** show up as a blue arrow. Ballast checks for them but never installs anything, so use Watchtower or `docker compose` for the actual update. For a compose container, right-click the row and choose **Copy update command** to get the commands for an SSH session on the NAS.

  Restarting a container won't update it, and neither will **Build** in Container Manager, because both reuse the image already on the NAS until you pull a new one. Container Manager also misses updates to a lot of images hosted outside Docker Hub (LinuxServer's `lscr.io`, for example) and will say "up to date" when they aren't. Ballast asks each image's own registry instead.
- **History** (⌘Y) lists exits, crashes, restarts and updates. Crash notifications can be turned on in Settings.
- **App updates:** Ballast checks GitHub once a day and tells you when a new version is out. Settings → About shows the version you're running and has **Check Now**.
- **Shortcuts:** ⌥⌘B opens the menu from anywhere. Inside it, ⌘F filters, ⌘R refreshes and ⌘, opens Settings.
- **Quit** by right-clicking the menu bar icon.

## Container labels

You can add these to your compose files if the defaults don't fit:

| Label | Effect |
|---|---|
| `ballast.url` | Use this exact URL |
| `ballast.port` | Which published port is the web UI |
| `ballast.scheme` | `http` or `https` |
| `ballast.path` | Append a path, e.g. `/web` |
| `ballast.name` | Display name |
| `ballast.group` | Group with other containers |
| `ballast.hide` | `true` to hide it |
| `ballast.notify` | `false` to never notify about it |
| `ballast.updates` | `false` to skip update checks |

With no labels, Ballast picks a port from the container's published ports.

## Development

```sh
./scripts/test.sh                  # unit tests
open Ballast/Ballast.xcodeproj     # build and run
./scripts/release.sh               # signed, notarised DMG in dist/
```

To run against sample data instead of a real NAS:

```sh
defaults write com.mediumrare.ballast BallastUseFixtures -bool YES
```

`release.sh` doesn't publish anything; when it finishes, it prints the `git tag` and `gh release create` commands for you to run.

## License

Ballast is released under the [GNU General Public License v3.0](LICENSE).
