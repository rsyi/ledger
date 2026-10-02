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

PROGRAM_SLICE="$(cd "$APP" && dart run tool/program_slice.dart --date "$TARGET" 2>/dev/null \
  || cat "$FIT/coach/routine.md")"

# Update program_status + coach_flags tabs (|| true so a failure doesn't
# kill the briefing; errors land in the log).
(cd "$APP" && dart run tool/program_status_update.dart) || true

PROGRAM_STATUS_BRIEF="$(cd "$APP" && dart run tool/program_status_update.dart --brief 2>/dev/null)" || true

# Sunday: the recomp weekly review (recomp_review.dart) for the Mon-Sun
# week just finishing — the full update above also rewrote the
# weekly_review tab.
WEEKLY_REVIEW=""
if [ "$(date +%u)" = "7" ]; then
  WEEKLY_REVIEW="$(cd "$APP" && dart run tool/program_status_update.dart --weekly-brief 2>/dev/null)" || true
fi

# Missed work this Mon-Sun week (+ moves, remaining days, expiry) for
# the coach's carryover proposal. Read-only; a failure must never stop
# the briefing.
MISSED="$(cd "$APP" && dart run tool/missed_work.dart --date "$TARGET" 2>/dev/null)" || true

PROMPT="$(
  printf 'MODE: BRIEFING\n\n'
  cat "$FIT/coach/PROMPT.md"
  printf '\n\n# goals.md\n\n';   cat "$FIT/coach/goals.md"
  printf '\n\n# program_slice\n\n%s\n' "$PROGRAM_SLICE"
  if [ -n "$PROGRAM_STATUS_BRIEF" ]; then
    printf '\n\n# program_status\n\n%s\n' "$PROGRAM_STATUS_BRIEF"
  fi
  if [ -n "$WEEKLY_REVIEW" ]; then
    printf '\n\n# weekly_review (generated tonight)\n\n%s\n' "$WEEKLY_REVIEW"
  fi
  if [ -n "$MISSED" ]; then
    printf '\n\n# missed_work\n\n%s\n' "$MISSED"
  fi
  printf '\n\n# metrics.md\n\n'; cat "$FIT/coach/metrics.md"
  # Templates retired (2026-09-30): the program_slice above is the
  # authoritative day-by-day prescription; program.yaml `routine:` holds
  # the full weekly structure.
  printf '\n\n# Ledger dump\n\n%s\n' "$DUMP"
)"

# Max-plan session via the claude CLI; sonnet is plenty and gentler on
# plan limits. Output is plain text — posted as the briefing; an optional
# fenced ```moves block (missed-work carryover) is split off by
# --split-moves, validated against TARGET's week (invalid moves dropped +
# logged) and posted as a kind=proposal card AFTER the briefing (a bad
# block is stripped + logged, never blocks the briefing).
OUT="$(claude -p "$PROMPT" --model sonnet --output-format text)"

printf '%s' "$OUT" | (cd "$APP" && dart run tool/coach_msg.dart post --role coach --kind briefing --split-moves --target "$TARGET" --thread briefings)
echo "=== coach run done $(date) ==="
