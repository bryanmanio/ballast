#!/bin/sh
#
# Runs the BallastCore unit tests.
#
# The scratch path is deliberately outside the repo: this project lives in a
# Synology Drive synced folder, and the sync client stamps Finder metadata onto
# build products, which makes codesign reject the test bundle with "resource
# fork, Finder information, or similar detritus not allowed".

set -eu
cd "$(dirname "$0")/.."
exec swift test --scratch-path "${TMPDIR:-/tmp/}ballast-swiftpm" "$@"
