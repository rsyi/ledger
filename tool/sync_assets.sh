#!/usr/bin/env bash
# Copies external sources (schemas repo, service-account key, config) into the
# Flutter assets/ directory so the app can load them at runtime on every
# platform (Android, iOS, macOS, web).
#
# Run this before `flutter run` whenever schemas change.

set -euo pipefail
cd "$(dirname "$0")/.."

SCHEMAS_SRC="${SCHEMAS_SRC:-$HOME/repos/airledger-schemas/views}"
TEMPLATES_SRC="${TEMPLATES_SRC:-$HOME/repos/airledger-schemas/templates}"
SA_KEY_SRC="${SA_KEY_SRC:-$HOME/.config/airledger/service-account.json}"
CONFIG_SRC="${CONFIG_SRC:-$HOME/.config/airledger/config.yaml}"

mkdir -p assets/schemas assets/templates

# Schemas: clear and recopy so deletions in the source propagate. Copies
# all paired files (.view.yml, .input.yml, .template.yml) into one flat
# assets/schemas/ dir — basename pairing keeps them associated.
rm -f assets/schemas/*.yml
shopt -s nullglob 2>/dev/null || true
for ext in view.yml input.yml template.yml; do
  files=("$SCHEMAS_SRC"/*."$ext")
  if [ ${#files[@]} -gt 0 ] && [ -e "${files[0]}" ]; then
    cp "$SCHEMAS_SRC"/*."$ext" assets/schemas/ 2>/dev/null || true
  fi
done
echo "synced $(ls assets/schemas/*.view.yml 2>/dev/null | wc -l | tr -d ' ') view(s)"\
  " + $(ls assets/schemas/*.input.yml 2>/dev/null | wc -l | tr -d ' ') input overlay(s)"\
  " + $(ls assets/schemas/*.template.yml 2>/dev/null | wc -l | tr -d ' ') template(s) from $SCHEMAS_SRC"

# Legacy templates/ dir is no longer used — clear any stale artifacts so
# they don't leak into the bundle. Templates now live alongside views,
# paired by basename: views/<view>.<name>.template.yml.
rm -rf assets/templates

# Legacy apps/ assets are gone (the .app.yml runtime was removed
# 2026-09-21, superseded by domain dashboards) — clear stale copies.
rm -rf assets/apps

# Service account key. Optional since multi-user (2026-10-03): a build
# without one ships `{}` and users sign in with Google for their own sheet
# (lib/services/google_auth/). The owner build keeps the baked key.
if [ -f "$SA_KEY_SRC" ]; then
  cp "$SA_KEY_SRC" assets/service-account.json
  echo "synced service-account.json"
else
  echo '{}' > assets/service-account.json
  echo "no service account at $SA_KEY_SRC — wrote {} (per-user Google sign-in build)"
fi

# Config: extract just the bits the app needs at runtime (spreadsheet_id).
# The other config keys (paths) are now baked into asset paths.
SPREADSHEET_ID=$(grep -E '^spreadsheet_id:' "$CONFIG_SRC" | sed 's/spreadsheet_id:[[:space:]]*//')
cat > assets/config.yaml <<EOF
spreadsheet_id: $SPREADSHEET_ID
EOF
echo "synced config.yaml (spreadsheet_id=$SPREADSHEET_ID)"
