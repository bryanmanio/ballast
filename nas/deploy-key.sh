#!/bin/sh
#
# Runs on the Mac. Installs your SSH public key on the Synology in a
# root-owned location, so key auth works without DSM's user home service.
#
#     ./nas/deploy-key.sh ballast-nas
#     ./nas/deploy-key.sh ballast@nas.local ~/.ssh/id_ballast.pub
#
# Password authentication is used for this one run. All the steps share a
# single SSH connection, so you are asked for the password once (and once
# more by sudo on the NAS).

set -eu

DEST=${1:-}
PUBKEY=${2:-$HOME/.ssh/id_ballast.pub}

if [ -z "$DEST" ]; then
    echo "usage: $0 <ssh-destination> [path-to-pubkey]" >&2
    echo "  e.g. $0 ballast-nas" >&2
    exit 2
fi
[ -f "$PUBKEY" ] || { echo "no public key at $PUBKEY" >&2; exit 1; }

SRC_DIR=$(cd "$(dirname "$0")" && pwd)
REMOTE_DIR="/tmp/ballast-key.$$"
CONTROL="${TMPDIR:-/tmp/}ballast-deploy.$$"

# One connection for every step below, so the password is asked for once
# rather than once per command.
SSH_OPTS="-o ControlMaster=auto -o ControlPersist=600 -o ControlPath=$CONTROL"

cleanup() {
    ssh -o ControlPath="$CONTROL" -O exit "$DEST" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "Connecting to $DEST (password required once)"
# shellcheck disable=SC2086
ssh $SSH_OPTS "$DEST" true

# shellcheck disable=SC2086
USERNAME=$(ssh $SSH_OPTS "$DEST" 'id -un' | tr -d '\r\n')
[ -n "$USERNAME" ] || { echo "could not determine the remote username" >&2; exit 1; }
echo "Remote user: $USERNAME"

# shellcheck disable=SC2086
ssh $SSH_OPTS "$DEST" "mkdir -p $REMOTE_DIR"

# Streamed with cat rather than scp: scp on OpenSSH 9+ requires an SFTP
# subsystem that DSM does not enable by default.
# shellcheck disable=SC2086
ssh $SSH_OPTS "$DEST" "cat > $REMOTE_DIR/install-key.sh" < "$SRC_DIR/install-key.sh"
# shellcheck disable=SC2086
ssh $SSH_OPTS "$DEST" "cat > $REMOTE_DIR/$(basename "$PUBKEY")" < "$PUBKEY"

echo "Running installer (sudo password required)"
# shellcheck disable=SC2086
ssh $SSH_OPTS -t "$DEST" \
    "cd $REMOTE_DIR && sudo sh install-key.sh '$USERNAME' '$REMOTE_DIR/$(basename "$PUBKEY")'; rc=\$?; rm -rf $REMOTE_DIR; exit \$rc"

echo
echo "Checking key authentication on a fresh connection"
# Deliberately not multiplexed: this has to prove the key works on its own.
if ssh -o BatchMode=yes -o PreferredAuthentications=publickey \
       -o ControlPath=none "$DEST" true 2>/dev/null; then
    echo "Key authentication works. Next:"
    echo "    ./nas/deploy.sh $DEST"
else
    echo "Key authentication is still failing." >&2
    echo "Keep an SSH session open and check the installer output above." >&2
    exit 1
fi
