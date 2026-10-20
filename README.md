# Ballast

A macOS menu bar app that lists the services running in Docker on a Synology
NAS, shows whether each one is actually up, and opens it in a browser on click.

## How it works

Ballast runs a small read-only script on the NAS over SSH and parses what it
prints. There is no daemon, no exposed Docker socket, and no credential stored
in the app — it reuses your existing SSH key and `~/.ssh/config`.

```
Mac                                 Synology
───                                 ────────
Ballast ──ssh──▶ sudo ballast-agent list ──▶ docker inspect
         ◀──── tab-separated JSON records ────
         ──http──▶ each service's own URL (liveness probe)
```

Status comes from Docker, merged worst-wins:

| Signal | Answers |
|---|---|
| Docker state | Is the container running, stopped, restarting? |
| `HEALTHCHECK` | Does the image think the service is healthy? |

There is a third signal available — an HTTP request to each service's URL —
which catches a container that is running, passing its healthcheck, and
serving nothing. It is **off by default**, because it reports a service as
degraded for reasons that have nothing to do with the service: the Mac's
network path, a slow first response, a port that doesn't speak HTTP. A status
you can't trust is worse than no status. Turn it on in Settings → Connection
if you want it.

## Setup

### 1. Set up key authentication

Enable SSH on the NAS (Control Panel → Terminal & SNMP). The account you use
must be in the **administrators** group — DSM refuses SSH logins for everyone
else.

Ballast runs unattended, so it needs key authentication; it can't answer a
password prompt. If you don't already have a key:

```sh
ssh-keygen -t ed25519 -f ~/.ssh/id_ballast -C "ballast"
```

Leave the passphrase empty, for the same reason.

Normally you'd `ssh-copy-id` into the account's home directory, but that
requires DSM's user home service, which creates a `homes` shared folder you
may not want. To avoid it:

```sh
./nas/deploy-key.sh ballast@nas.local ~/.ssh/id_ballast.pub
```

This puts the key in `/etc/ssh/authorized_keys/<user>`, owned by root, and
points sshd at that directory. No user home service, no `homes` share — and
the account can't alter the key that grants access to it, which it could if
the key lived in its own home directory.

It backs up `sshd_config`, validates the new config with `sshd -t` before
restarting, and restores the backup if validation fails. **Keep an SSH session
open while you run it** — that's the safety net if sshd won't come back.

A DSM major update can reset `sshd_config`; re-run this script if Ballast
later reports "SSH login refused".

If you'd rather use the conventional path, enable Control Panel → User & Group
→ Advanced → User Home, then `ssh-copy-id` as usual and skip this script.

### 2. Install the agent on the NAS

From this repo:

```sh
./nas/deploy.sh you@nas.local     # or an ~/.ssh/config alias
```

This copies `ballast-agent` to `/usr/local/bin`, makes it root-owned, and adds
a single sudoers rule scoped to that one script. DSM asks for your password
once during install; after that the agent runs without one.

**Why a wrapper script rather than `sudo docker`:** DSM's Docker socket is
root-only, so something has to be granted passwordless root. Granting it for
the whole `docker` binary is equivalent to handing that user root on the NAS.
`ballast-agent` exposes only read-only inspection, so the grant is bounded by
what the script can do.

The script must stay root-owned and not writable by your SSH user — otherwise
the sudo rule becomes a way to get root. `install.sh` enforces this, and
refuses to install into a directory that isn't root-owned.

### 3. Point the app at the NAS

Open Settings with the gear in the top right of the menu — it opens a window
with a source list: **General**, **Connection**, **Menu**, **Notifications**,
**History** and **About**. Under **Connection**, fill in:

- **SSH destination** — `user@host`, or an alias from `~/.ssh/config`
- **Local hostname** — used to build each service's URL (defaults to the host
  part of the SSH destination)
- **Remote hostname** — optional; a Tailscale name works well here. When the
  local hostname doesn't answer, Ballast switches to this one, so the same
  menu works away from home.

"Test connection" reports exactly what's wrong if something isn't right:
agent missing, sudo not configured, Docker stopped, host unreachable, and so
on — each with the specific fix.

## Controlling containers

Hovering a row replaces its port with restart and stop buttons — or start, if
the container is stopped. The same actions are in the row's right-click menu.

These are the only operations that change anything on the NAS. The agent
validates the container reference against the live container list before
passing it to Docker, and the reference travels as its own argument rather
than inside a command string, so nothing in a container name can reach a
shell. Anything broader than start/stop/restart would turn the sudoers grant
back into unrestricted root, which is the thing the wrapper script exists to
avoid.

## Hiding containers

Right-click a container and choose **Hide from menu**. Hidden containers are
listed under Settings → Menu → Hidden, each with a Show button.

This is stored on the Mac, keyed by container name, and changes nothing on the
NAS. Name rather than id, because `docker compose up` gives a container a new
id every time it's recreated — hiding by id would silently stop working. For a
container you never want to see from anywhere, use the `ballast.hide` label
instead.

## Opening the menu from the keyboard

Settings → General has a **global hotkey**, ⌥⌘B out of the box, which opens
and closes the menu from wherever you are. Click the shortcut to record a new
one, or the ⓧ beside it to have no shortcut at all. It's registered through
Carbon's hot key API rather than an event monitor, so Ballast never asks for
Accessibility access — it can't see any keystroke but this one.

If another app already owns the combination, the field says so rather than
leaving a key that quietly does nothing.

## Quitting

Ballast has no Dock icon and no app menu, so Quit lives in a context menu:
right-click the menu bar icon, or right-click anywhere in the menu that isn't
a container row.

## Display options

In Settings → Menu:

- **Sort by** — `Status` puts anything needing attention first and sorts
  alphabetically within each status, so a healthy list still reads
  alphabetically. `Name` ignores status entirely.
- **Hide project names** — on by default. Shows one flat list instead of
  grouping containers under their compose stack.

Settings → General controls how often Ballast looks: an interval, and a
**Refresh automatically** switch. Turned off, nothing is polled in the
background — opening the menu or pressing the refresh button still fetches the
current state.

The magnifying glass in the menu's header reveals a filter field (Escape
closes it). When any container is stopped, a Running / Stopped / All control
appears so stopped containers are one click away rather than a scroll to the
bottom.

## Downtime history and notifications

Ballast compares each poll with the last successful one, so a container that
crashed at 03:00 and was restarted by Docker no longer leaves no trace. The
clock-with-arrow button in the header opens **History**: exits, crash-restarts
and starts, newest first and grouped by day, with "down for 4m" where both the
exit and the next start were seen. A container's tooltip also shows its last
exit. The log is a JSON file in `~/Library/Application Support/Ballast`, capped
at 200 events and 30 days.

A notification fires only for an exit with a **non-zero code or an
out-of-memory kill**, and only once you turn it on in Settings → Notifications
(macOS asks for permission then, not at launch). These are recorded but never
notify:

- a clean `exit 0`
- a container Docker's restart policy already brought back between two polls
- anything you stop, start or restart from Ballast's own menu — `docker stop`
  can end in a SIGKILL (exit 137) that would otherwise look like a crash

An exit is worded from when Docker says it happened. If the Mac was asleep, you
get "Exited with code 137, 6 hours ago" rather than something that reads as
just now. If a poll finds more than three new exits at once (a NAS reboot), they
arrive as a single notification. To silence one container, use **Mute exit
notifications** on its right-click menu, or the `ballast.notify=false` label;
muted containers are listed under Settings → Menu → Muted.
Tapping a notification doesn't do anything yet.

## Per-container configuration

Labels in your compose files, so nothing has to be configured on the Mac:

| Label | Effect |
|---|---|
| `ballast.url` | Use this exact URL (handy behind a reverse proxy) |
| `ballast.port` | Which published port is the web UI |
| `ballast.scheme` | Force `http` or `https` |
| `ballast.path` | Append a path, e.g. `/web` |
| `ballast.name` | Display name |
| `ballast.group` | Group with other containers (compose stacks group automatically) |
| `ballast.probe` | `false` to skip the HTTP check |
| `ballast.hide` | `true` to keep it out of the menu |
| `ballast.notify` | `false` to never notify about its exits (still recorded in History) |

Without any labels, Ballast uses the container's published ports, preferring
ones that look like web UIs and ignoring loopback-only bindings, which aren't
reachable from the Mac anyway.

Containers that share another container's network namespace — the usual VPN
sidecar arrangement — have no ports of their own. Ballast matches their
exposed ports against the owner's published bindings. When a service was told
to listen on a port its image doesn't declare (qBittorrent with `WEBUI_PORT`,
say) there is nothing to match on, and Docker records nothing tying a
namespace port to the container using it; Ballast then offers the owner's
ports that no sibling has claimed. That last step is a guess — set
`ballast.port` to be certain.

## Development

```sh
./scripts/test.sh                      # unit tests
open Ballast/Ballast.xcodeproj       # build and run
```

Run the UI against sample data, with no NAS involved:

```sh
defaults write com.bryanmaniotakis.ballast BallastUseFixtures -bool YES
defaults write com.bryanmaniotakis.ballast BallastDebugWindow -bool YES
defaults write com.bryanmaniotakis.ballast BallastSettingsWindow -bool YES
```

The first drives the menu from `FixtureContainerSource`; the second also opens
the menu's contents in an ordinary window, which is far easier to inspect and
screenshot than a menu bar popover; the third opens Settings at launch, for
the same reason. Fixture mode keeps its settings in a
separate defaults domain, so it can't disturb a real configuration. Turn both
off with `defaults delete com.bryanmaniotakis.ballast`.

### Layout

- `Ballast/Ballast/Core` — all logic: transport, parsing, URL resolution,
  status assessment, downtime detection and history. No SwiftUI.
- `Ballast/Ballast/UI` — the menu, rows, settings.
- `nas/` — the agent script and its installer.
- `Tests/` — unit tests over `Core`.

`Package.swift` points a SwiftPM target at `Ballast/Ballast/Core` so
`swift test` can exercise that logic directly, with no duplicated sources and
no test target wired into `project.pbxproj`. One side effect: editors that
read `Package.swift` will report errors for the SwiftUI files, which aren't
part of any package target. The Xcode build is the source of truth.

Tests build into a scratch directory outside the repo (see `scripts/test.sh`)
because this project lives in a Synology Drive synced folder, and the sync
client stamps metadata onto build products that makes codesign reject them.

## Not built yet

Deliberately out of the first version, with the architecture left open for them:

- Log viewer
- Real-time Docker events instead of polling, via
  `docker system dial-stdio` — `ContainerSource` exists as a protocol so this
  can be swapped in without touching the UI
