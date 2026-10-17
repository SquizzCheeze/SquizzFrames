#!/bin/sh
# The 1.x key check (2.0 design doc, "Setup and moving from 1.x"): no setting
# a 1.x profile holds may be silently dropped. Run before shipping:
#
#     sh .tools/check-keys.sh [tag]      (default v1.40)
#
# Takes every key in that tag's Defaults/*.lua and reports:
#   1. keys no longer named anywhere in the current Lua code;
#   2. keys the tag's code read OUTSIDE Defaults/ that the current code only
#      mentions inside Defaults/ (the reader was deleted, the default stayed);
#   3. per-indicator setting tokens (IndicatorDefaults.lua) that are gone.
# Anything listed must be explained (a migration converts it, or it belonged
# to something deliberately removed) before shipping. Slow (~2 min): it greps
# every key against two trees.
set -e
TAG=${1:-v1.40}
cd "$(dirname "$0")/.."
TMP=$(mktemp -d)
for f in $(git ls-tree -r --name-only "$TAG" -- Defaults | grep '\.lua$'); do
    git show "$TAG:$f" > "$TMP/$(basename "$f")"
done
perl .tools/keys.pl "$TMP"/*.lua > "$TMP/keys.txt"
echo "$(wc -l < "$TMP/keys.txt") keys in $TAG's defaults"

echo "--- 1. no longer named anywhere:"
while read -r k; do
    git grep -qw -- "$k" -- '*.lua' ':!Libs' || echo "  $k"
done < "$TMP/keys.txt"

echo "--- 2. reader deleted (named outside Defaults in $TAG, only inside now):"
while read -r k; do
    if git grep -qw -- "$k" "$TAG" -- '*.lua' ':!Libs' ':!Defaults' \
        && ! git grep -qw -- "$k" -- '*.lua' ':!Libs' ':!Defaults'; then
        echo "  $k"
    fi
done < "$TMP/keys.txt"

echo "--- 3. indicator setting tokens gone:"
git show "$TAG:Modules/Indicators/IndicatorDefaults.lua" | grep -oE '"[A-Za-z0-9_:-]+"' | sort -u > "$TMP/old.txt"
grep -oE '"[A-Za-z0-9_:-]+"' Modules/Indicators/IndicatorDefaults.lua | sort -u > "$TMP/new.txt"
comm -23 "$TMP/old.txt" "$TMP/new.txt" | sed 's/^/  /'

rm -rf "$TMP"
echo "--- done"
