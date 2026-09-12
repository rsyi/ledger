#!/usr/bin/env bash
# Coach chat relay: when the user has sent messages after the coach's last
# message, feed the full history + fresh ledger context to headless Claude
# and post its plain-text reply back to the coach_chat tab. Safe to run
# often (launchd/cron); exits silently when there's nothing pending.
set -euo pipefail

APP="$HOME/repos/airledger-archive"
FIT="$HOME/repos/airledger-fitness"
LOGDIR="$HOME/.config/airledger/coach/logs"
mkdir -p "$LOGDIR"
LOG="$LOGDIR/relay-$(date +%F).log"
exec >>"$LOG" 2>&1

# exit 3 = nothing pending (or missing tab) -> silent no-op. Treat any
# non-zero as "nothing to do" but log real failures (exit != 3).
set +e
HISTORY=$(cd "$APP" && dart run tool/coach_msg.dart pending)
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  if [ "$rc" -ne 3 ]; then
    echo "=== relay $(date): pending check failed (exit $rc) ==="
  fi
  exit 0
fi

echo "=== relay run start $(date) ==="

# Fresh goals/routine in case they were edited from another machine.
git -C "$FIT" pull --ff-only || echo "warn: fitness pull failed, using local copy"

DUMP="$(cd "$APP" && dart run tool/coach_dump.dart --days 28)"

PROMPT="$(
  printf 'MODE: REPLY\n\n'
  cat "$FIT/coach/PROMPT.md"
  printf '\n\n# goals.md\n\n';   cat "$FIT/coach/goals.md"
  printf '\n\n# routine.md\n\n'; cat "$FIT/coach/routine.md"
  printf '\n\n# metrics.md\n\n'; cat "$FIT/coach/metrics.md"
  printf '\n\n# Templates\n\n'
  for t in "$FIT"/views/*.template.yml; do
    printf -- '--- %s ---\n' "$(basename "$t")"; cat "$t"; printf '\n'
  done
  printf '\n\n# Ledger dump\n\n%s\n' "$DUMP"
  printf '\n\n# Chat history\n\n%s\n' "$HISTORY"
)"

OUT="$(claude -p "$PROMPT" --model sonnet --output-format text)"

printf '%s' "$OUT" | (cd "$APP" && dart run tool/coach_msg.dart post --role coach --kind reply)
echo "=== relay run done $(date) ==="
