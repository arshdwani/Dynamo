#!/bin/bash
# Publishes a new version of Dynamo:
#   Tools/release.sh 1.3 "- Added X
#   - Fixed Y"
# Bumps the version, runs the tests, commits, tags, pushes and creates the GitHub
# Release. Installed copies see it within a day and show an Update button.
set -euo pipefail
cd "$(dirname "$0")/.."

V="${1:-}"
NOTES="${2:-}"
if [[ ! "$V" =~ ^[0-9]+(\.[0-9]+)+$ ]]; then
    echo "usage: Tools/release.sh <version> [release notes]" >&2; exit 1
fi
if [[ -n "$(git status --porcelain)" ]]; then
    echo "Commit (or stash) your changes first; the release is made from what's committed." >&2; exit 1
fi
if git rev-parse -q --verify "refs/tags/v$V" >/dev/null; then
    echo "v$V already exists." >&2; exit 1
fi

sed -i '' "s/^let appVersion = \".*\"/let appVersion = \"$V\"/" Sources/Shared/Version.swift
./build.sh test
git commit -qam "Dynamo $V"
git tag "v$V"
git push -q origin main "v$V"

BODY="${NOTES:-See the commits since the previous release.}

**To update:** click **Update** in Dynamo's panel, or run \`git pull && ./install.sh\` in your Dynamo folder."
gh release create "v$V" --title "Dynamo $V" --notes "$BODY"
