#!/bin/bash
# Pulls Apple's aerial masters and transcodes each to the display profile, one at a time.
# Resumable: an asset whose mp4 already exists is skipped, so re-running costs one manifest
# fetch. The next master downloads while the current one encodes, which is most of the
# wall-clock saving, and each master is deleted as soon as its mp4 lands so peak disk is the
# output set plus two sources rather than twice the output set.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${BIN:-$ROOT/.build/release/kino}"
DEST="${DEST:-$HOME/Library/Wallpapers}"
STAGE="$DEST/.staging"
MANIFEST="https://sylvan.apple.com/Aerials/resources-16.tar"
VARIANT="${VARIANT:-url-4K-SDR}"

[ -x "$BIN" ] || { echo "build first: swift build -c release -Xswiftc -gnone"; exit 2; }
mkdir -p "$DEST" "$STAGE"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "fetching manifest"
curl -sS --retry 3 -o "$work/r.tar" "$MANIFEST" || { echo "manifest fetch failed"; exit 1; }
tar -xf "$work/r.tar" -C "$work" entries.json || { echo "manifest has no entries.json"; exit 1; }

# any shot ids given as arguments select a subset; none means the whole catalogue
printf '%s\n' "$@" > "$work/want"
python3 - "$work/entries.json" "$VARIANT" "$work/want" > "$work/list" <<'PY'
import json, re, sys
entries, variant = json.load(open(sys.argv[1])), sys.argv[2]
want = {l.strip() for l in open(sys.argv[3]) if l.strip()}
for a in entries["assets"]:
    if variant not in a: continue
    if want and a["shotID"] not in want: continue
    label = re.sub(r"[^A-Za-z0-9]+", "-", a.get("accessibilityLabel", "aerial")).strip("-")
    print(f"{label}-{a['shotID']}\t{a[variant]}")
PY

total=$(wc -l < "$work/list" | tr -d ' ')
echo "$total assets selected, variant $VARIANT"
if [ "$#" -gt 0 ] && [ "$total" -ne "$#" ]; then
  echo "warning: asked for $# shot ids, matched $total. unmatched:"
  cut -f1 "$work/list" | sed 's/.*-\([A-Za-z0-9_]*\)$/\1/' > "$work/got"
  grep -vxF -f "$work/got" "$work/want" | sed 's/^/  /'
fi

pull() { curl -sS -L -C - --retry 3 --retry-delay 2 -o "$2" "$1"; }

n=0; done_count=0; skipped=0; failed=0
next_pid=""; next_src=""
while IFS=$'\t' read -r name url; do
  n=$((n + 1))
  out="$DEST/$name.mp4"
  src="$STAGE/$name.mov"

  if [ -s "$out" ]; then skipped=$((skipped + 1)); continue; fi

  # the previous iteration may already have this one in flight
  if [ "$next_src" = "$src" ] && [ -n "$next_pid" ]; then
    wait "$next_pid"; rc=$?
  else
    pull "$url" "$src"; rc=$?
  fi
  next_pid=""; next_src=""

  if [ $rc -ne 0 ] || [ ! -s "$src" ]; then
    echo "[$n/$total] $name: download failed"; failed=$((failed + 1)); rm -f "$src"; continue
  fi

  # start the next master downloading before spending minutes in the encoder
  peek=$(awk -v i=$((n + 1)) 'NR==i' "$work/list")
  if [ -n "$peek" ]; then
    pname="${peek%%$'\t'*}"; purl="${peek#*$'\t'}"
    if [ ! -s "$DEST/$pname.mp4" ]; then
      next_src="$STAGE/$pname.mov"
      pull "$purl" "$next_src" & next_pid=$!
    fi
  fi

  # encode to a scratch name and rename on success, so a run killed mid-encode leaves no
  # half-written mp4 for the resume check to mistake for a finished one
  echo "[$n/$total] $name"
  if "$BIN" prep "$src" -o "$out.part" | sed 's/^/    /'; then
    mv -f "$out.part" "$out"
    done_count=$((done_count + 1))
  else
    echo "    encode failed"; failed=$((failed + 1)); rm -f "$out.part"
  fi
  rm -f "$src"
done < "$work/list"

[ -n "$next_pid" ] && wait "$next_pid" 2>/dev/null
rm -f "$STAGE"/*.mov 2>/dev/null; rmdir "$STAGE" 2>/dev/null

echo "encoded $done_count, skipped $skipped already present, failed $failed"
du -sh "$DEST" 2>/dev/null
