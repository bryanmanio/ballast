# Ballast

A macOS menu bar app that lists the Docker containers running on a Synology
NAS, shows whether each one is up, and opens it in your browser on click.

Ballast connects over SSH using your existing key and `~/.ssh/config`, and runs
a small script on the NAS that only reads from Docker. There's no daemon, no
exposed Docker socket, and no credentials stored in the app.

## Setup

On first launch, a setup window walks you through these steps with each
command ready to copy. You can reopen it later from **Set up Ballast…** in the
menu.

1. **Enable SSH** on the NAS (Control Panel → Terminal & SNMP), using an
   account in the administrators group. A dedicated account works well, and
   you can deny it every application in DSM.
2. **Add a key** with no passphrase:
   ```sh
   ssh-keygen -t ed25519 -f ~/.ssh/id_ballast -C "ballast"
   ./nas/deploy-key.sh ballast-user@nas.local ~/.ssh/id_ballast.pub
   ```
   Keep another SSH session open while this runs. It edits `sshd_config`.
3. **Install the agent:**
   ```sh
   ./nas/deploy.sh ballast-user@nas.local
   ```
   This installs a root-owned script that only reads from Docker and can
   start, stop or restart a container, and allows only that script to run
   with sudo.
4. **Point the app at the NAS** under Settings → Connection, then click
   **Test connection**.

If a DSM update resets `sshd_config`, run `deploy-key.sh` again.

## Features

- **Status** comes from Docker's state and each container's healthcheck.
- **Start, stop and restart** a container by hovering its row or
  right-clicking it.
- **Image updates:** a blue arrow means a newer image is available. Ballast
  only checks for updates and never installs them. Use Watchtower or
  `docker compose` for that. For a compose container, right-click the row and
  choose **Copy update command** to get the commands to paste into an SSH
  session on the NAS.

  Restarting a container doesn't update it, and neither does **Build** in
  Container Manager. Both reuse the image already on the NAS. The image has to
  be pulled first. Container Manager also often misses updates to images
  hosted outside Docker Hub, such as LinuxServer's `lscr.io`, so it can say
  "up to date" when Ballast doesn't. Ballast asks the image's own registry.
- **History** (⌘Y) lists exits, crashes, restarts and updates. You can turn
  on notifications for crashes in Settings.
- **Global hotkey:** ⌥⌘B opens the menu.
- **Inside the menu:** ⌘F filters, ⌘R refreshes and ⌘, opens Settings.
- **Quit** by right-clicking the menu bar icon.

## Container labels

Optional labels in your compose files:

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

Without labels, Ballast picks a port from the container's published ports.

## Development

```sh
./scripts/test.sh                  # unit tests
open Ballast/Ballast.xcodeproj     # build and run
./scripts/release.sh               # signed, notarised DMG in dist/
```

To run the app against sample data instead of a NAS:

```sh
defaults write com.mediumrare.ballast BallastUseFixtures -bool YES
```

`release.sh` doesn't publish anything. After it finishes, it prints the `git
tag` and `gh release create` commands to run.

The website is in [ballast-site](https://github.com/bryanmanio/ballast-site).
