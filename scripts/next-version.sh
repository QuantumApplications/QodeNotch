#!/bin/bash
# Computes the next semantic version from Conventional Commits.
#
#   ./scripts/next-version.sh            # prints KEY=VALUE lines (version, previous, bump, changelog file)
#
# Rules (commits since the last vX.Y.Z tag reachable from HEAD):
#   - no tag yet                                   → 1.0.0 (first release)
#   - "BREAKING CHANGE:" in a body or "type!:"     → major
#   - any "feat:" / "feat(scope):"                 → minor
#   - anything else (fix, chore, docs, …)          → patch
#   - no commits since the last tag                → bump=none (nothing to release)
#
# The changelog (Markdown, grouped by type) is written to $CHANGELOG_FILE
# (default: build/CHANGELOG.md).
set -euo pipefail

cd "$(dirname "$0")/.."
FIRST_VERSION="${FIRST_VERSION:-1.0.0}"
CHANGELOG_FILE="${CHANGELOG_FILE:-build/CHANGELOG.md}"
mkdir -p "$(dirname "$CHANGELOG_FILE")"

last_tag=$(git describe --tags --abbrev=0 --match 'v[0-9]*.[0-9]*.[0-9]*' 2>/dev/null || true)
if [ -n "$last_tag" ]; then
  range="$last_tag..HEAD"
else
  range="HEAD"
fi

# One record per commit: subject, then body, separated by NUL.
subjects=$(git log --format='%s' $range)
bodies=$(git log --format='%B' $range)

if [ -n "$last_tag" ] && [ -z "$subjects" ]; then
  echo "version=${last_tag#v}"
  echo "previous=${last_tag#v}"
  echo "bump=none"
  echo "changelog_file=$CHANGELOG_FILE"
  : > "$CHANGELOG_FILE"
  exit 0
fi

if [ -z "$last_tag" ]; then
  bump="initial"
  version="$FIRST_VERSION"
  previous=""
else
  previous="${last_tag#v}"
  IFS=. read -r major minor patch <<< "$previous"
  if grep -qE '^[a-z]+(\([^)]*\))?!:' <<< "$subjects" || grep -qE '^BREAKING[ -]CHANGE:' <<< "$bodies"; then
    bump="major"; major=$((major + 1)); minor=0; patch=0
  elif grep -qE '^feat(\([^)]*\))?:' <<< "$subjects"; then
    bump="minor"; minor=$((minor + 1)); patch=0
  else
    bump="patch"; patch=$((patch + 1))
  fi
  version="$major.$minor.$patch"
fi

# Changelog grouped by commit type.
section() {
  local title="$1" pattern="$2" lines
  lines=$(grep -E "$pattern" <<< "$subjects" | sed -E 's/^[a-z]+(\([^)]*\))?!?: */- /' || true)
  if [ -n "$lines" ]; then
    printf '### %s\n%s\n\n' "$title" "$lines"
  fi
}
{
  section "⚠️ Breaking Changes" '^[a-z]+(\([^)]*\))?!:'
  section "Features" '^feat(\([^)]*\))?:'
  section "Fixes" '^fix(\([^)]*\))?:'
  section "Performance" '^perf(\([^)]*\))?:'
  other=$(grep -vE '^(feat|fix|perf)(\([^)]*\))?!?:' <<< "$subjects" | grep -vE '^[a-z]+(\([^)]*\))?!:' | grep -vE '^Merge ' | sed 's/^/- /' || true)
  if [ -n "$other" ]; then
    printf '### Other\n%s\n\n' "$other"
  fi
} > "$CHANGELOG_FILE"

echo "version=$version"
echo "previous=$previous"
echo "bump=$bump"
echo "changelog_file=$CHANGELOG_FILE"
