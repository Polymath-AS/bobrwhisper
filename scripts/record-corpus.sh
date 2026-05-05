#!/usr/bin/env bash
#
# Record a baseline test corpus for tuning.
#
# Records 12 phrases × 2 modes (normal + whispered) = 24 snippets total.
# Phrases are tagged short / question / technical so the corpus can be
# sliced via:  bobrwhisper-cli tune --group-by tag
#
# Usage:
#   ./scripts/record-corpus.sh             # press 'q' + Enter to stop each take
#   ./scripts/record-corpus.sh -d 5        # fixed 5-second takes (no 'q' needed)
#
# Environment:
#   CLI=path/to/bobrwhisper-cli            # override binary location

set -u

CLI="${CLI:-./zig-out/bin/bobrwhisper-cli}"
DURATION=()

while getopts "d:h" opt; do
  case "$opt" in
    d) DURATION=(--duration "$OPTARG") ;;
    h) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "Usage: $0 [-d seconds]" >&2; exit 2 ;;
  esac
done

if [[ ! -x "$CLI" ]]; then
  echo "snippet CLI not found at: $CLI" >&2
  echo "Build it first: zig build" >&2
  exit 1
fi

# 12 phrases. Edit to match your accent/vocabulary; keep the tag column the
# same so per-tag averages stay comparable across runs.
SHORT=(
  "yes please"
  "open settings"
  "no thanks"
  "stop recording"
)
QUESTION=(
  "what time is it"
  "who is calling me"
  "what is the weather today"
  "where is the nearest coffee"
)
TECHNICAL=(
  "refactor the parser"
  "git rebase onto main"
  "evaluate this codebase"
  "the lexer tokenizes input"
)

CURRENT=0
TOTAL=$(( (${#SHORT[@]} + ${#QUESTION[@]} + ${#TECHNICAL[@]}) * 2 ))

bar() { printf '──────────────────────────────────────────────\n'; }

record_one() {
  local label="$1" tag="$2" mode="$3"
  CURRENT=$((CURRENT + 1))

  local mode_flag
  case "$mode" in
    whisper) mode_flag="--whisper" ;;
    normal)  mode_flag="--no-whisper" ;;
    *) echo "internal error: unknown mode $mode" >&2; exit 3 ;;
  esac

  printf '\n'; bar
  printf '  [%2d/%d]  %-40s  %s\n' "$CURRENT" "$TOTAL" "\"$label\"" "$mode ($tag)"
  bar
  printf 'Enter to record, "s" to skip, "q" to quit: '
  read -r choice
  case "$choice" in
    s|S) printf '  skipped.\n'; return ;;
    q|Q) printf '  quitting.\n'; exit 0 ;;
  esac

  # The snippet CLI segfaults on shutdown after the WAV+JSON are written;
  # tolerate the non-zero exit so the script keeps going.
  "$CLI" snippet --label "$label" "$mode_flag" --tag "$tag" "${DURATION[@]}" || true
}

run_set() {
  local tag="$1"; shift
  for phrase in "$@"; do
    for mode in normal whisper; do
      record_one "$phrase" "$tag" "$mode"
    done
  done
}

cat <<EOF
Recording corpus: $TOTAL snippets (12 phrases × normal + whispered).
For each take, speak the phrase, then press 'q' then Enter to stop
(or wait if you passed -d).

EOF
read -rp 'Ready? Press Enter to start... '

run_set short     "${SHORT[@]}"
run_set question  "${QUESTION[@]}"
run_set technical "${TECHNICAL[@]}"

cat <<EOF

Done. Quick views:

  $CLI tune --gain auto --group-by tag
  $CLI tune --gain auto --group-by mode
  $CLI tune --gain auto --group-by device      # after recording on a 2nd mic
EOF
