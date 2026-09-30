#!/usr/bin/env bash
#
# refresh-fork-altstore.sh [notes] — point altstore-fork.json at this fork's newest testing build.
#
# Run after the "Testing build (fork)" workflow finishes. Downloads the IPA from the rolling
# `testing-latest` release, reads its real CFBundleIdentifier / version / build / size, and rewrites the
# single version entry in altstore-fork.json. Then commit + push, and SideStore sees the update.
#
# Everything is read FROM THE IPA rather than passed in, because the source file's job is to describe the
# artifact that actually exists. A hand-typed version that disagrees with the binary is how a source ends
# up offering an "update" that installs the same build, or refusing one that is genuinely new.
#
# Usage:
#   Tools/refresh-fork-altstore.sh "what changed in this build"
set -euo pipefail

REPO="${FORK_REPO:-dbAbstract/noop}"
TAG="${FORK_TAG:-testing-latest}"
# The branch the source JSON is SERVED from. `fork` is the long-lived integration branch, deliberately
# not a feature branch: the URL is pasted into SideStore once and should outlive whatever is being worked
# on. Only used to sanity-check that this file is being refreshed on the branch that actually serves it.
SERVE_BRANCH="${FORK_SERVE_BRANCH:-fork}"
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../altstore-fork.json"
NOTES="${1:-}"

command -v gh >/dev/null || { echo "✗ gh is required" >&2; exit 1; }
command -v jq >/dev/null || { echo "✗ jq is required (brew install jq)" >&2; exit 1; }
[ -f "$SRC" ] || { echo "✗ $SRC not found" >&2; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Refreshing this file on a branch nobody serves produces a green run and a source that never changes,
# which is indistinguishable from "no new build" on the phone. Warn rather than fail: refreshing it on a
# feature branch before merging to the serve branch is a legitimate order of operations.
CUR_BRANCH="$(git -C "$HERE/.." rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
if [ "$CUR_BRANCH" != "$SERVE_BRANCH" ]; then
  echo "⚠ on branch '$CUR_BRANCH' but SideStore reads '$SERVE_BRANCH'." >&2
  echo "  Merge this into $SERVE_BRANCH and push, or the phone will not see the change." >&2
fi

echo "→ downloading the $TAG IPA from $REPO"
gh release download "$TAG" --repo "$REPO" --pattern '*.ipa' --dir "$TMP" --clobber
IPA="$(find "$TMP" -maxdepth 1 -name '*.ipa' | head -1)"
[ -n "$IPA" ] || { echo "✗ no .ipa asset on $TAG" >&2; exit 1; }

# The download URL must be the ASSET NAME on the rolling tag: the tag is stable but the filename carries
# MARKETING_VERSION, so it changes whenever that is bumped. Deriving it from the file we just fetched
# keeps the two in step instead of leaving a dead link behind a version bump.
ASSET="$(basename "$IPA")"
URL="https://github.com/$REPO/releases/download/$TAG/$ASSET"
SIZE="$(/usr/bin/stat -f%z "$IPA")"

unzip -qq "$IPA" -d "$TMP/x"
PLIST="$(find "$TMP/x/Payload" -maxdepth 2 -name Info.plist | head -1)"
[ -n "$PLIST" ] || { echo "✗ no Payload/*.app/Info.plist in the IPA" >&2; exit 1; }
BUNDLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")"
SHORT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
DATE="$(date -u +%Y-%m-%d)"
DESC="${NOTES:-"Fork testing build $SHORT ($BUILD)."}"

PREV_BUILD="$(jq -r '.apps[0].versions[0].buildVersion // ""' "$SRC")"
PREV_SHORT="$(jq -r '.apps[0].versions[0].version // ""' "$SRC")"
if [ "$SHORT" = "$PREV_SHORT" ] && [ "$BUILD" = "$PREV_BUILD" ]; then
  # Not fatal — the file is still refreshed — but SideStore keys "an update exists" off version+build, so
  # an unchanged pair means it will NOT offer this build even though the asset behind the URL is new.
  echo "⚠ version+build unchanged ($SHORT/$BUILD): SideStore will not offer this as an update." >&2
  echo "  Bump CURRENT_PROJECT_VERSION in project.yml and re-run the workflow to make it visible." >&2
fi

jq --arg v "$SHORT" --arg b "$BUILD" --arg d "$DATE" --arg desc "$DESC" \
   --arg url "$URL" --argjson size "$SIZE" --arg bundle "$BUNDLE" \
   '.apps[0].bundleIdentifier = $bundle
    | .apps[0].versions = [{
        version: $v, buildVersion: $b, date: $d, localizedDescription: $desc,
        downloadURL: $url, size: $size, minOSVersion: "17.0"
      }]' "$SRC" > "$TMP/out.json"
mv "$TMP/out.json" "$SRC"

echo "✓ altstore-fork.json → $BUNDLE $SHORT ($BUILD), $SIZE bytes"
echo "  $URL"
echo
echo "Next: git add altstore-fork.json && git commit -m 'chore: point fork source at build $BUILD' && git push"
