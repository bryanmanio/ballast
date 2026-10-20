#!/bin/sh
#
# Runs ON the Synology, as root (via sudo). Installs ballast-agent and a
# sudoers grant scoped to it. Use nas/deploy.sh from the Mac to drive this.
#
#     sudo sh install.sh [ssh-username]

set -eu

AGENT_DEST=/usr/local/bin/ballast-agent
SUDOERS_DEST=/etc/sudoers.d/ballast
SRC_DIR=$(dirname "$0")

die() { echo "error: $1" >&2; exit 1; }
say() { echo "  $1"; }

[ "$(id -u)" = "0" ] || die "must run as root: sudo sh install.sh"

# Who will be invoking the agent over SSH.
TARGET_USER=${1:-${SUDO_USER:-}}
[ -n "$TARGET_USER" ] || die "cannot determine the SSH username; pass it as an argument"
id "$TARGET_USER" >/dev/null 2>&1 || die "no such user: $TARGET_USER"

[ -f "$SRC_DIR/ballast-agent" ] || die "ballast-agent not found next to install.sh"

echo "Installing ballast-agent for user '$TARGET_USER'"

# --- the agent ------------------------------------------------------------
# A NOPASSWD grant is only as safe as the thing it points at. If the target
# script or its directory were writable by the SSH user, that user could
# replace the script body and run arbitrary code as root. Refuse to install
# into such a location rather than creating that hole quietly.
DEST_DIR=$(dirname "$AGENT_DEST")
[ -d "$DEST_DIR" ] || mkdir -p "$DEST_DIR"
if [ -w "$DEST_DIR" ] && [ "$(stat -c '%U' "$DEST_DIR" 2>/dev/null)" != "root" ]; then
    die "$DEST_DIR is not root-owned; refusing to install a sudo target there"
fi

cp "$SRC_DIR/ballast-agent" "$AGENT_DEST"
chown root:root "$AGENT_DEST"
chmod 0755 "$AGENT_DEST"
say "installed $AGENT_DEST ($(stat -c '%U:%G %a' "$AGENT_DEST"))"

"$AGENT_DEST" check >/dev/null 2>&1 || die "agent self-check failed; is Container Manager running?"
say "agent self-check passed ($("$AGENT_DEST" check | grep '^docker-server' || true))"

# Actually run a listing here, so a bad Docker template or an unexpected
# Docker version fails loudly now rather than silently at first use.
LIST_OUTPUT=$("$AGENT_DEST" list 2>&1) || die "agent list failed: $LIST_OUTPUT"
echo "$LIST_OUTPUT" | head -1 | grep -q '^#ballast ' || die "agent list produced no header"
echo "$LIST_OUTPUT" | tail -1 | grep -q '^#end ' || die "agent list produced no terminator"
say "listed $(echo "$LIST_OUTPUT" | tail -1 | cut -d' ' -f2) containers"

# --- the sudoers grant ----------------------------------------------------
RULE="$TARGET_USER ALL=(root) NOPASSWD: $AGENT_DEST"

if grep -qE '^[[:space:]]*#includedir[[:space:]]+/etc/sudoers.d' /etc/sudoers 2>/dev/null; then
    TMP_RULE=$(mktemp)
    printf '# Installed by Ballast. Scoped to one read-only command.\n%s\n' "$RULE" > "$TMP_RULE"
    chmod 0440 "$TMP_RULE"

    # Validate before committing: a malformed sudoers file can lock the NAS
    # out of sudo entirely.
    if command -v visudo >/dev/null 2>&1; then
        visudo -c -f "$TMP_RULE" >/dev/null || { rm -f "$TMP_RULE"; die "sudoers rule failed validation"; }
        say "sudoers rule validated"
    else
        say "visudo not available; skipping validation"
    fi

    mv "$TMP_RULE" "$SUDOERS_DEST"
    chown root:root "$SUDOERS_DEST"
    chmod 0440 "$SUDOERS_DEST"
    say "installed $SUDOERS_DEST"
else
    echo
    echo "  /etc/sudoers has no '#includedir /etc/sudoers.d' line, so the drop-in"
    echo "  was not installed. Add this line manually with 'sudo visudo':"
    echo
    echo "      $RULE"
    echo
fi

# Remove the predecessor installed under the project's former name, so its
# passwordless sudo grant doesn't outlive the rename.
for legacy in /usr/local/bin/porthole-agent /etc/sudoers.d/porthole; do
    if [ -e "$legacy" ]; then
        rm -f "$legacy"
        say "removed legacy $legacy"
    fi
done

echo
echo "Done. Verify from your Mac:"
echo "    ssh $TARGET_USER@<nas> sudo -n $AGENT_DEST check"
echo
echo "Note: a DSM major upgrade can clear /usr/local/bin. If Ballast later"
echo "reports the agent as missing, re-run nas/deploy.sh."
