#!/bin/sh
#
# Runs ON the Synology, as root. Installs an SSH public key into a root-owned
# location so key authentication works without DSM's user home service.
#
#     sudo sh install-key.sh <username> <path-to-pubkey>
#
# Keys live in /etc/ssh/authorized_keys/<user> rather than ~/.ssh, which means
# no "homes" shared folder has to exist, and the account itself cannot modify
# the key that grants access to it.

set -eu

KEY_DIR=/etc/ssh/authorized_keys
SSHD_CONFIG=/etc/ssh/sshd_config
WANTED_LINE="AuthorizedKeysFile $KEY_DIR/%u .ssh/authorized_keys"

die() { echo "error: $1" >&2; exit 1; }
say() { echo "  $1"; }

[ "$(id -u)" = "0" ] || die "must run as root: sudo sh install-key.sh <user> <pubkey>"

TARGET_USER=${1:-}
PUBKEY_PATH=${2:-}
[ -n "$TARGET_USER" ] || die "usage: sudo sh install-key.sh <username> <path-to-pubkey>"
[ -n "$PUBKEY_PATH" ] || die "usage: sudo sh install-key.sh <username> <path-to-pubkey>"
id "$TARGET_USER" >/dev/null 2>&1 || die "no such user: $TARGET_USER"
[ -f "$PUBKEY_PATH" ] || die "no public key at $PUBKEY_PATH"

grep -qE '^(ssh-(rsa|ed25519|dss)|ecdsa-sha2-|sk-)' "$PUBKEY_PATH" \
    || die "$PUBKEY_PATH does not look like an SSH public key"

echo "Installing SSH key for '$TARGET_USER'"

# --- the key ---------------------------------------------------------------
mkdir -p "$KEY_DIR"
chown root:root "$KEY_DIR"
chmod 755 "$KEY_DIR"

DEST="$KEY_DIR/$TARGET_USER"
if [ -f "$DEST" ] && grep -qxF "$(cat "$PUBKEY_PATH")" "$DEST"; then
    say "key already present in $DEST"
else
    cat "$PUBKEY_PATH" >> "$DEST"
    say "added key to $DEST"
fi
chown root:root "$DEST"
chmod 644 "$DEST"

# --- sshd configuration ----------------------------------------------------
# The directive is only effective if it appears before the first Match block,
# since everything after a Match line belongs to that block. So check for the
# line AND its position, not just its presence.
MARKER="# Added by Ballast: root-owned keys, so no user home is required."

line_no=$(grep -nxF "$WANTED_LINE" "$SSHD_CONFIG" 2>/dev/null | head -1 | cut -d: -f1)
match_no=$(grep -nE '^[[:space:]]*[Mm]atch[[:space:]]' "$SSHD_CONFIG" 2>/dev/null | head -1 | cut -d: -f1)

CONFIGURED=no
if [ -n "$line_no" ]; then
    if [ -z "$match_no" ] || [ "$line_no" -lt "$match_no" ]; then
        CONFIGURED=yes
    else
        say "found the directive inside a Match block, where it has no effect; fixing"
    fi
fi

if [ "$CONFIGURED" = "yes" ]; then
    say "sshd already configured"
    RESTART_NEEDED=no
else
    BACKUP="$SSHD_CONFIG.ballast-backup.$(date +%Y%m%d%H%M%S)"
    cp "$SSHD_CONFIG" "$BACKUP"
    say "backed up config to $BACKUP"

    TMP_CONFIG=$(mktemp)

    # Drop any directive a previous run of this script left behind, then
    # comment out any other AuthorizedKeysFile rather than deleting it, so
    # the original intent stays visible in the file.
    grep -vxF "$MARKER" "$SSHD_CONFIG" \
        | grep -vxF "$WANTED_LINE" \
        | sed 's/^[[:space:]]*AuthorizedKeysFile/#&/' > "$TMP_CONFIG.stripped"

    awk -v line="$WANTED_LINE" -v marker="$MARKER" '
        !done && /^[[:space:]]*[Mm]atch[[:space:]]/ {
            print marker
            print line
            print ""
            done = 1
        }
        { print }
        END {
            if (!done) {
                print ""
                print marker
                print line
            }
        }
    ' "$TMP_CONFIG.stripped" > "$TMP_CONFIG"

    cat "$TMP_CONFIG" > "$SSHD_CONFIG"
    rm -f "$TMP_CONFIG" "$TMP_CONFIG.stripped"

    # Validate before restarting. A bad sshd_config that gets loaded would
    # lock SSH out of the NAS entirely.
    SSHD_BIN=$(command -v sshd || echo /usr/bin/sshd)
    [ -x "$SSHD_BIN" ] || SSHD_BIN=/usr/sbin/sshd
    if [ -x "$SSHD_BIN" ]; then
        if ! "$SSHD_BIN" -t 2>/tmp/ballast-sshd-test.txt; then
            cp "$BACKUP" "$SSHD_CONFIG"
            die "sshd rejected the new config (restored backup): $(cat /tmp/ballast-sshd-test.txt)"
        fi
        say "sshd validated the new config"
    else
        say "WARNING: could not find sshd to validate the config"
    fi
    RESTART_NEEDED=yes
fi

if [ "$RESTART_NEEDED" = "yes" ]; then
    if synosystemctl restart sshd >/dev/null 2>&1 \
        || systemctl restart sshd >/dev/null 2>&1 \
        || synoservicectl --restart sshd >/dev/null 2>&1; then
        say "restarted sshd"
    else
        say "WARNING: restart the SSH service manually (Control Panel -> Terminal & SNMP)"
    fi

    # DSM is known to regenerate sshd_config from its own template when the
    # service restarts. If that happened, say so plainly rather than leaving
    # a silent failure to debug later.
    if ! grep -qxF "$WANTED_LINE" "$SSHD_CONFIG"; then
        say "WARNING: DSM rewrote sshd_config on restart; the directive did not survive"
    fi
fi

echo
echo "Effective configuration:"
grep -nE '^[[:space:]]*(AuthorizedKeysFile|StrictModes|PubkeyAuthentication|Match)' "$SSHD_CONFIG" \
    | sed 's/^/    /'
echo "  key file:"
ls -l "$DEST" 2>&1 | sed 's/^/    /'

echo
echo "Done. KEEP THIS SESSION OPEN and verify from another terminal on your Mac:"
echo "    ssh -o BatchMode=yes $TARGET_USER@<nas> id"
