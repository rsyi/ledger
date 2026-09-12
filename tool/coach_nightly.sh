#!/usr/bin/env bash
# Nightly AI coach: dump ledger context -> headless Claude (Max plan)
# -> apply draft rows + coach_log summary. Scheduled by launchd
# (com.robertyi.airledger-coach, 23:30 daily); safe to run manually.
# Disable: launchctl unload ~/Library/LaunchAgents/com.robertyi.airledger-coach.plist
set -euo pipefail

APP="$HOME/repos/airledger-archive"
FIT="$HOME/repos/airledger-fitness"
LOGDIR="$HOME/.config/airledger/coach/logs"
mkdir -p "$LOGDIR"
LOG="$LOGDIR/$(date +%F).log"
exec >>"$LOG" 2>&1
echo "=== coach run start $(date) ==="

# Fresh goals/routine in case they were edited from another machine.
git -C "$FIT" pull --ff-only || echo "warn: fitness pull failed, using local copy"

DUMP="$(cd "$APP" && dart run tool/coach_dump.dart --days 28)"

PROMPT="$(
  cat "$FIT/coach/PROMPT.md"
  printf '\n\n# goals.md\n\n';   cat "$FIT/coach/goals.md"
  printf '\n\n# routine.md\n\n'; cat "$FIT/coach/routine.md"
  printf '\n\n# metrics.md\n\n'; cat "$FIT/coach/metrics.md"
  printf '\n\n# Templates\n\n'
  for t in "$FIT"/views/*.template.yml; do
    printf -- '--- %s ---\n' "$(basename "$t")"; cat "$t"; printf '\n'
  done
  printf '\n\n# Ledger dump\n\n%s\n' "$DUMP"
)"

# Max-plan session via the claude CLI; sonnet is plenty for the strict
# JSON contract and gentler on plan limits.
OUT="$(claude -p "$PROMPT" --model sonnet --output-format text)"

# Tolerate accidental fences/preamble: keep first '{' .. last '}'.
JSON="$(printf '%s' "$OUT" | python3 -c '
import sys
s = sys.stdin.read()
a, b = s.find("{"), s.rfind("}")
sys.exit(1) if a < 0 or b <= a else print(s[a:b+1])
')"

printf '%s' "$JSON" | (cd "$APP" && dart run tool/coach_apply.dart)
echo "=== coach run done $(date) ==="
