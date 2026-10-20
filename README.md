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
you can't trust is worse than no status. Turn it on in Settings if you want
it.

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

Open Settings with the gear in the top right of the menu, and fill in:

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
listed under Settings → Hidden, each with a Show button.

This is stored on the Mac, keyed by container name, and changes nothing on the
NAS. Name rather than id, because `docker compose up` gives a container a new
id every time it's recreated — hiding by id would silently stop working. For a
container you never want to see from anywhere, use the `ballast.hide` label
instead.

## Quitting

Ballast has no Dock icon and no app menu, so Quit lives in a context menu:
right-click the menu bar icon, or right-click anywhere in the menu that isn't
a container row.

## Display options

In Settings:

- **Sort by** — `Status` puts anything needing attention first and sorts
  alphabetically within each status, so a healthy list still reads
  alphabetically. `Name` ignores status entirely.
- **Hide project names** — on by default. Shows one flat list instead of
  grouping containers under their compose stack.

The magnifying glass in the menu's header reveals a filter field (Escape
closes it). When any container is stopped, a Running / Stopped / All control
appears so stopped containers are one click away rather than a scroll to the
bottom.

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
```

The first drives the menu from `FixtureContainerSource`; the second also opens
the menu's contents in an ordinary window, which is far easier to inspect and
screenshot than a menu bar popover. Fixture mode keeps its settings in a
separate defaults domain, so it can't disturb a real configuration. Turn both
off with `defaults delete com.bryanmaniotakis.ballast`.

### Layout

- `Ballast/Ballast/Core` — all logic: transport, parsing, URL resolution,
  status assessment. No SwiftUI.
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

- Restart / start / stop from the menu
- Downtime history and notifications when a container exits unexpectedly
- Log viewer
- Real-time Docker events instead of polling, via
  `docker system dial-stdio` — `ContainerSource` exists as a protocol so this
  can be swapped in without touching the UI
