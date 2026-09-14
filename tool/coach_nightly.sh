#!/usr/bin/env bash
# Nightly AI coach: dump ledger context -> headless Claude (Max plan)
# -> post a plain-text briefing to the coach_chat tab. Scheduled by launchd
# (com.robertyi.airledger-coach, 23:30 daily); safe to run manually.
# Disable: launchctl unload ~/Library/LaunchAgents/com.robertyi.airledger-coach.plist
set -euo pipefail

APP="$HOME/repos/ledger"
FIT="$HOME/repos/airledger-fitness"
LOGDIR="$HOME/.config/airledger/coach/logs"
mkdir -p "$LOGDIR"
LOG="$LOGDIR/$(date +%F).log"
exec >>"$LOG" 2>&1
echo "=== coach run start $(date) ==="

# Fresh goals/routine in case they were edited from another machine.
git -C "$FIT" pull --ff-only || echo "warn: fitness pull failed, using local copy"

# Idempotence: skip if a briefing was already posted for the planning target.
TARGET=$(cd "$APP" && dart run tool/coach_dump.dart --days 1 --views coach_chat | awk '/^PLANNING TARGET:/ {print $3}')
if (cd "$APP" && dart run tool/coach_msg.dart briefing-exists --date "$TARGET"); then
  echo "briefing already posted for $TARGET"
  exit 0
fi

DUMP="$(cd "$APP" && dart run tool/coach_dump.dart --days 28)"

PROMPT="$(
  printf 'MODE: BRIEFING\n\n'
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

# Max-plan session via the claude CLI; sonnet is plenty and gentler on
# plan limits. Output is plain text — posted verbatim as the briefing.
OUT="$(claude -p "$PROMPT" --model sonnet --output-format text)"

printf '%s' "$OUT" | (cd "$APP" && dart run tool/coach_msg.dart post --role coach --kind briefing --thread briefings)
echo "=== coach run done $(date) ==="
