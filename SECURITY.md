# Security policy

Ballast runs commands on your NAS as root, through a sudo rule scoped to a single script (`nas/ballast-agent`). A bug that lets someone get past that scope, or reach your NAS through the app, matters a lot more than an ordinary bug, so please report it privately.

## Supported versions

Only the latest release gets security fixes. If you're on an older version, update first and check whether the problem is still there.

## Reporting a vulnerability

Please don't open a public issue. Use [private vulnerability reporting](https://github.com/bryanmanio/ballast/security/advisories/new) on GitHub.

A useful report includes:

- the Ballast version (Settings → About) and your macOS and DSM versions
- what an attacker needs to start with, for example access to the SSH account, to the Mac, or to the local network
- steps to reproduce, or a proof of concept
- what they can do once it works

Once a fix is out, I'll credit you in the release notes unless you'd rather I didn't.

## What's in scope

- `nas/ballast-agent`, `nas/install.sh` and the sudoers rule it writes, especially anything that lets the SSH user run a Docker command other than `list`, `images`, `check`, `version`, `start`, `stop` or `restart`, or run anything as root
- the deploy scripts in `nas/`
- the macOS app, including how it builds SSH commands and handles output from the NAS
- the update check against GitHub releases

Problems in Docker, DSM, OpenSSH or the container images you run belong with those projects.
