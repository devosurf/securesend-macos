#!/bin/bash
set -euo pipefail

# Moves the app to a new version. One script, because the git tag, the two
# Info.plist version keys and the name on the release page are the same number,
# and Check for updates compares the number in the bundle against the number on
# the release page. The release workflow refuses to build a tag whose plist
# disagrees with it, so this is the only supported way to bump.
#
#   ./scripts/version.sh 0.2.0

VERSION="${1:-}"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
	echo "usage: scripts/version.sh X.Y.Z" >&2
	exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLIST="$ROOT/Resources/Info.plist"

if [ -n "$(git -C "$ROOT" status --porcelain)" ]; then
	echo "the working tree has changes in it. Commit or stash them first." >&2
	exit 1
fi

if git -C "$ROOT" rev-parse -q --verify "refs/tags/v$VERSION" > /dev/null; then
	echo "v$VERSION is already a tag." >&2
	exit 1
fi

# Edited as text rather than with PlistBuddy or plutil, both of which rewrite the
# whole file and throw away the comments in it. The Services comment in there is
# the reason the app has no key equivalents, and it is worth keeping.
for KEY in CFBundleShortVersionString CFBundleVersion; do
	VERSION="$VERSION" KEY="$KEY" perl -0pi -e '
		my $key = $ENV{KEY};
		my $version = $ENV{VERSION};
		s{(<key>\Q$key\E</key>\s*<string>)[^<]*(</string>)}{$1$version$2}
	' "$PLIST"
done

plutil -lint "$PLIST" > /dev/null

for KEY in CFBundleShortVersionString CFBundleVersion; do
	READ_BACK="$(/usr/libexec/PlistBuddy -c "Print :$KEY" "$PLIST")"
	if [ "$READ_BACK" != "$VERSION" ]; then
		echo "$KEY reads $READ_BACK after the edit, not $VERSION." >&2
		git -C "$ROOT" checkout -- "$PLIST"
		exit 1
	fi
done

# Already at this version and only the tag missing, which is what a run that
# failed after the commit leaves behind. Tag it rather than refusing over an
# empty commit.
if [ -n "$(git -C "$ROOT" status --porcelain)" ]; then
	git -C "$ROOT" commit --quiet -am "release: v$VERSION"
fi

git -C "$ROOT" tag "v$VERSION"

echo "committed and tagged v$VERSION."
echo "push it and the release builds itself:"
echo
echo "  git push --follow-tags"
