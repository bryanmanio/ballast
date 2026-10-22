#!/bin/sh
#
# Runs on the Mac. Copies the agent to the Synology and installs it there.
#
#     ./nas/deploy.sh ballast-nas
#     ./nas/deploy.sh you@nas.local
#
# Run nas/deploy-key.sh first if key authentication isn't set up yet. DSM
# prompts for the sudo password once; after that the agent runs without one.

set -eu

DEST=${1:-}
if [ -z "$DEST" ]; then
    echo "usage: $0 <ssh-destination>" >&2
    echo "  e.g. $0 ballast-nas" >&2
    exit 2
fi

SRC_DIR=$(cd "$(dirname "$0")" && pwd)
REMOTE_DIR="/tmp/ballast-install.$$"
CONTROL="${TMPDIR:-/tmp/}ballast-install.$$"

# The key setup makes, which ssh would never offer on its own: it only looks
# for its default names. Those are named too, because naming any key stops ssh
# trying them. The same keys the app offers, so the final check below means
# what it says. A literal ~, which ssh expands itself.
KEY_OPTS=""
if [ -f "$HOME/.ssh/id_ballast" ]; then
    for key in id_ballast id_rsa id_ecdsa id_ecdsa_sk id_ed25519 id_ed25519_sk; do
        KEY_OPTS="$KEY_OPTS -o IdentityFile=~/.ssh/$key"
    done
fi

# Share one connection across every step, so no step re-prompts.
SSH_OPTS="-o ControlMaster=auto -o ControlPersist=600 -o ControlPath=$CONTROL$KEY_OPTS"

cleanup() {
    ssh -o ControlPath="$CONTROL" -O exit "$DEST" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "Connecting to $DEST"
# shellcheck disable=SC2086
ssh $SSH_OPTS "$DEST" true

echo "Copying agent to $REMOTE_DIR"
# shellcheck disable=SC2086
ssh $SSH_OPTS "$DEST" "mkdir -p $REMOTE_DIR"

# Streamed with cat rather than scp: scp on OpenSSH 9+ requires an SFTP
# subsystem that DSM does not enable by default.
# shellcheck disable=SC2086
ssh $SSH_OPTS "$DEST" "cat > $REMOTE_DIR/ballast-agent" < "$SRC_DIR/ballast-agent"
# shellcheck disable=SC2086
ssh $SSH_OPTS "$DEST" "cat > $REMOTE_DIR/install.sh" < "$SRC_DIR/install.sh"

echo "Running installer (sudo password required)"
# shellcheck disable=SC2086
ssh $SSH_OPTS -t "$DEST" \
    "cd $REMOTE_DIR && sudo sh install.sh; rc=\$?; rm -rf $REMOTE_DIR; exit \$rc"

echo
echo "Checking unattended access, exactly as the app does it"
# Not multiplexed, and no password fallback: this must pass on its own, or
# Ballast won't be able to connect either.
# shellcheck disable=SC2086
if ssh -o BatchMode=yes -o ControlPath=none $KEY_OPTS "$DEST" \
       "sudo -n /usr/local/bin/ballast-agent check"; then
    echo
    echo "Ready. Use '$DEST' as the SSH destination in Ballast's settings."
else
    echo
    echo "The agent installed but unattended access is not working." >&2
    echo "Check the sudoers instructions printed above." >&2
    exit 1
fi
