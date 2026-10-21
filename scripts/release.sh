#!/bin/sh
#
# Builds a signed, notarised Ballast.dmg ready to attach to a GitHub release.
#
#     ./scripts/release.sh                 # full run
#     ./scripts/release.sh --skip-notarize # local check, no Apple round trip
#     ./scripts/release.sh --output ~/dist # somewhere other than ./dist
#
# One-time setup is checked before anything is built, and the exact command to
# fix each missing piece is printed rather than left to be looked up.

set -eu

TEAM_ID=${BALLAST_TEAM_ID:-P7BP892R7G}           # Mediumrare Inc.
APPLE_ID=${BALLAST_APPLE_ID:-bryan@mediumrare.co}
NOTARY_PROFILE=${BALLAST_NOTARY_PROFILE:-ballast-notary}
SCHEME=Ballast
APP_NAME=Ballast

cd "$(dirname "$0")/.."
REPO=$(pwd)
PROJECT="$REPO/Ballast/Ballast.xcodeproj"
OUTPUT="$REPO/dist"
SKIP_NOTARIZE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --skip-notarize) SKIP_NOTARIZE=1; shift ;;
        --output) OUTPUT=$2; shift 2 ;;
        -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

die() { echo "error: $1" >&2; exit 1; }
say() { printf '\n==> %s\n' "$1"; }

notarise() {
    xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait \
        || die "notarisation failed; 'xcrun notarytool log <submission-id> --keychain-profile $NOTARY_PROFILE' says why"
}

# Everything intermediate is built outside the repo. This project lives in a
# Synology Drive synced folder, and the sync client stamps Finder metadata
# onto build products, which makes codesign reject a bundle with "resource
# fork, Finder information, or similar detritus not allowed".
SCRATCH="${TMPDIR:-/tmp/}ballast-release"
rm -rf "$SCRATCH"
mkdir -p "$SCRATCH" "$OUTPUT"

ARCHIVE="$SCRATCH/$APP_NAME.xcarchive"
EXPORTED="$SCRATCH/export"
STAGE="$SCRATCH/dmg"

# --- preflight ------------------------------------------------------------
# Signing and notarisation are one-time, interactive, and account-bound, so
# they are checked up front rather than failing twenty minutes into a build.

# A shipped build has to be traceable to a commit, so uncommitted changes
# would make the release irreproducible. A local check doesn't ship.
if [ "$SKIP_NOTARIZE" -eq 0 ] && [ -n "$(git status --porcelain)" ]; then
    git status --short | sed 's/^/  /' >&2
    die "the working tree has uncommitted changes; commit them, or use --skip-notarize for a local check"
fi
COMMIT=$(git rev-parse --short HEAD)

say "Checking signing identity"
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep "Developer ID Application" | grep "$TEAM_ID" \
    | head -1 | sed 's/.*"\(.*\)"/\1/') || true

if [ -z "${IDENTITY:-}" ]; then
    cat >&2 <<EOF
error: no "Developer ID Application" certificate for team $TEAM_ID.

  An Apple Development certificate is not enough — distributing outside the
  App Store needs a Developer ID Application one. Create it once:

      Xcode → Settings → Accounts → (your Apple ID) → Manage Certificates…
      → + → Developer ID Application

  Pick the Mediumrare Inc. team. If the + menu has it greyed out, the team's
  Account Holder has to create it at developer.apple.com → Certificates.
EOF
    exit 1
fi
echo "  $IDENTITY"

if [ "$SKIP_NOTARIZE" -eq 0 ]; then
    say "Checking notarisation credentials"
    # A stored profile that Apple rejects and no profile at all are different
    # problems with different fixes, so they get different messages rather
    # than one "check your credentials".
    NOTARY_ERROR=$(xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" 2>&1 >/dev/null) || NOTARY_FAILED=1

    if [ "${NOTARY_FAILED:-0}" -eq 1 ]; then
        echo "$NOTARY_ERROR" | sed 's/^/  /' >&2
        echo >&2

        case "$NOTARY_ERROR" in
            *401*|*"Invalid credentials"*)
                cat >&2 <<EOF
error: Apple rejected the credentials stored in "$NOTARY_PROFILE".

  The app-specific password has to belong to the Apple ID passed as
  --apple-id. Generating one while signed in as A and storing it against B
  is the usual cause, and it fails exactly like this.

  Re-store it with the Apple ID you generated the password under:

      xcrun notarytool store-credentials "$NOTARY_PROFILE" \\
          --apple-id "$APPLE_ID" \\
          --team-id "$TEAM_ID" \\
          --password "<app-specific-password>"

  Set BALLAST_APPLE_ID to use a different one. Note also that changing the
  account's main password revokes every app-specific password it had.
EOF
                ;;
            *)
                cat >&2 <<EOF
error: no usable notarytool profile called "$NOTARY_PROFILE".

  Store it once, with an app-specific password from account.apple.com
  (Sign-In and Security → App-Specific Passwords):

      xcrun notarytool store-credentials "$NOTARY_PROFILE" \\
          --apple-id "$APPLE_ID" \\
          --team-id "$TEAM_ID" \\
          --password "<app-specific-password>"
EOF
                ;;
        esac

        echo >&2
        echo "  Or re-run with --skip-notarize to check the build without submitting it." >&2
        echo "  An un-notarised build is refused by Gatekeeper on every Mac but this one." >&2
        exit 1
    fi
    echo "  profile $NOTARY_PROFILE"
fi

VERSION=$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
    -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/ MARKETING_VERSION /{print $2; exit}')
[ -n "${VERSION:-}" ] || die "couldn't read MARKETING_VERSION from the project"
DMG="$OUTPUT/$APP_NAME-$VERSION.dmg"

# --- build ----------------------------------------------------------------

say "Running unit tests"
TEST_LOG="$SCRATCH/test.log"
./scripts/test.sh >"$TEST_LOG" 2>&1 \
    || { tail -30 "$TEST_LOG" >&2; die "unit tests failed; full log at $TEST_LOG"; }
echo "  passed"

say "Archiving $APP_NAME $VERSION"
xcodebuild archive \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE" \
    -derivedDataPath "$SCRATCH/DerivedData" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    | grep -E '^(\*\*|error|warning)' || true
[ -d "$ARCHIVE" ] || die "archive failed; re-run without the output filter to see why"

say "Exporting with Developer ID"
cat > "$SCRATCH/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>teamID</key><string>$TEAM_ID</string>
    <key>signingStyle</key><string>automatic</string>
</dict>
</plist>
EOF

xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportPath "$EXPORTED" \
    -exportOptionsPlist "$SCRATCH/ExportOptions.plist" \
    | grep -E '^(\*\*|error|warning)' || true

APP="$EXPORTED/$APP_NAME.app"
[ -d "$APP" ] || die "export failed; no $APP_NAME.app at $EXPORTED"

# --- verify the app before wrapping it ------------------------------------

say "Verifying the app"
codesign --verify --strict --verbose=2 "$APP" 2>&1 | sed 's/^/  /'

# Notarisation rejects anything without the hardened runtime, and does it
# after the upload rather than before, so check here where it's cheap.
codesign -d -vvv "$APP" 2>&1 | grep -q 'flags=.*runtime' \
    || die "the app is not hardened-runtime signed (ENABLE_HARDENED_RUNTIME)"
echo "  hardened runtime on"

# Release archives build ARCHS_STANDARD, but an override anywhere in the
# project would quietly drop Intel Macs, which macOS 26 still supports.
ARCHS=$(lipo -archs "$APP/Contents/MacOS/$APP_NAME")
case "$ARCHS" in
    *arm64*x86_64*|*x86_64*arm64*) echo "  universal ($ARCHS)" ;;
    *) die "the binary is not universal: $ARCHS" ;;
esac

# The agent scripts are the reason the app is useful; a missing copy phase
# would otherwise only show up when a user pastes a broken command.
for script in ballast-agent install.sh install-key.sh deploy.sh deploy-key.sh; do
    [ -x "$APP/Contents/Resources/nas/$script" ] \
        || die "missing or non-executable: Contents/Resources/nas/$script"
done
echo "  nas/ scripts present and executable"

# --- notarise the app -----------------------------------------------------
# The app is notarised and stapled *before* it's packaged, as well as the
# image afterwards. Stapling only the image leaves the app without a ticket
# of its own once it's dragged to Applications: Gatekeeper then has to ask
# Apple over the network, and a Mac that's offline at first launch refuses to
# open it.

if [ "$SKIP_NOTARIZE" -eq 0 ]; then
    say "Notarising the app (a few minutes)"
    ditto -c -k --keepParent "$APP" "$SCRATCH/$APP_NAME.zip"
    notarise "$SCRATCH/$APP_NAME.zip"

    xcrun stapler staple "$APP"
    # Stapling writes into the bundle, so prove the seal still holds.
    codesign --verify --strict "$APP" || die "stapling broke the app's signature"
fi

# --- disk image -----------------------------------------------------------

say "Building the disk image"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
# The drag-to-install convention. It matters beyond habit: Launch at Login
# uses SMAppService, which refuses to register an app that isn't properly
# installed, and an app left in Downloads runs translocated from a random
# read-only path.
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGE" \
    -fs HFS+ \
    -format UDZO \
    -quiet \
    "$DMG"

codesign --sign "$IDENTITY" --timestamp "$DMG"
echo "  $DMG"

# The dSYMs are the only way to symbolicate a crash report from this exact
# build, and the archive they live in is about to be thrown away with the
# scratch directory. They stay out of the release itself.
DSYMS="$OUTPUT/$APP_NAME-$VERSION-$COMMIT-dSYMs.zip"
rm -f "$DSYMS"
ditto -c -k --keepParent "$ARCHIVE/dSYMs" "$DSYMS"
echo "  $DSYMS"

# --- notarise -------------------------------------------------------------

if [ "$SKIP_NOTARIZE" -eq 1 ]; then
    cat <<EOF

Built, unnotarised: $DMG

Gatekeeper will refuse this on any Mac but one where it was built. Re-run
without --skip-notarize to ship it.
EOF
    exit 0
fi

say "Notarising the image (a few minutes)"
notarise "$DMG"

say "Stapling the image"
xcrun stapler staple "$DMG"

# What a user's Mac will decide, asked the same way Gatekeeper asks it —
# of the image they download, and of the app they drag out of it.
say "Verifying as Gatekeeper would"
spctl -a -t open --context context:primary-signature -v "$DMG" 2>&1 | sed 's/^/  /'

MOUNT=$(hdiutil attach "$DMG" -nobrowse -readonly | tail -1 | awk '{print $NF}')
spctl -a -vv "$MOUNT/$APP_NAME.app" 2>&1 | sed 's/^/  /'
xcrun stapler validate "$MOUNT/$APP_NAME.app" >/dev/null 2>&1 \
    && echo "  ticket stapled to the app" \
    || { hdiutil detach "$MOUNT" -quiet; die "the app in the image has no stapled ticket"; }
hdiutil detach "$MOUNT" -quiet

# Written after stapling, which changes the image's bytes.
(cd "$OUTPUT" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
SHA=$(cut -d' ' -f1 "$DMG.sha256")

cat <<EOF

Done: $DMG
  built from $COMMIT
  sha256 $SHA

Tag and attach it to a release:
    git tag -a v$VERSION $COMMIT -m "Ballast $VERSION" && git push origin v$VERSION
    gh release create v$VERSION "$DMG" "$DMG.sha256" --verify-tag --title "Ballast $VERSION" --notes "..."
EOF
