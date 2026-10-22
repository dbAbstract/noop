#!/bin/bash
# FORK-LOCAL. The "What's new" text SideStore shows for a fork testing build: one line per change merged since the
# previously published build, newest first.
#
#   Tools/fork-build-notes.sh <build> <head-sha> [previous-sha]
#
# Walks first-parent history only, so an upstream sync reads as its one PR rather than as every upstream commit it
# brought in. A merged PR is named by its title (the merge commit's body) and number; a direct commit by its
# subject; the bot's own "point fork source" commits are skipped. Without a usable previous build (none recorded,
# or not an ancestor of head) it describes head alone. Capped at 15 lines, so the source stays small.
set -euo pipefail

build="$1"
head="$2"
prev="${3:-}"

if [ -n "$prev" ] && git merge-base --is-ancestor "$prev" "$head" 2>/dev/null; then
  commits="$(git rev-list --first-parent "$prev..$head")"
else
  commits="$head"
fi

lines=""
count=0
total=0
for c in $commits; do
  subject="$(git log -1 --format=%s "$c")"
  case "$subject" in "chore: point fork source at build"*) continue ;; esac
  total=$((total + 1))
  [ "$count" -ge 15 ] && continue
  if [ "$(git rev-list --parents -n1 "$c" | wc -w)" -gt 2 ]; then
    title="$(git log -1 --format=%b "$c" | sed -n '/[^[:space:]]/{p;q;}')"
    pr="$(printf '%s' "$subject" | sed -nE 's/^Merge pull request (#[0-9]+).*/\1/p')"
    if [ -n "$title" ]; then line="$title${pr:+ ($pr)}"; else line="$subject"; fi
  else
    line="$subject"
  fi
  lines="${lines}• $line"$'\n'
  count=$((count + 1))
done

[ "$total" -gt "$count" ] && lines="${lines}• …and $((total - count)) more"$'\n'
printf 'Build %s (%s)\n\n%s' "$build" "$(git rev-parse --short "$head")" "${lines:-• No changes recorded.}"
