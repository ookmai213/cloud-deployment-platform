#!/usr/bin/env bash
# Isolated integration test for the user's deployment script rollback functions.
set -Eeuo pipefail
SCRIPT="${1:-scripts/deploy-ubuntu.sh}"
[[ -f "$SCRIPT" ]] || { echo "FAIL: script not found: $SCRIPT" >&2; exit 1; }
ROOT="$(mktemp -d)"
trap 'rm -rf -- "$ROOT"' EXIT
mkdir -p "$ROOT/live/app/app" "$ROOT/live/app/.venv/bin" "$ROOT/live/web" "$ROOT/backups/app-root/app" "$ROOT/backups/app-root/.venv/bin" "$ROOT/backups/website" "$ROOT/live/etc" "$ROOT/stub"
printf 'bad' > "$ROOT/live/app/app/main.py"
printf 'working' > "$ROOT/backups/app-root/app/main.py"
printf 'fastapi' > "$ROOT/backups/app-root/app/requirements.txt"
: > "$ROOT/backups/app-root/.venv/bin/python"; chmod +x "$ROOT/backups/app-root/.venv/bin/python"
printf 'bad-page' > "$ROOT/live/web/index.html"
printf 'good-page' > "$ROOT/backups/website/index.html"
printf 'old nginx' > "$ROOT/backups/nginx.conf"
printf 'new nginx' > "$ROOT/live/etc/nginx.conf"
printf 'old unit' > "$ROOT/backups/linux-web-api.service"
printf 'new unit' > "$ROOT/live/etc/linux-web-api.service"
ln -s "$ROOT/live/etc/nginx.conf" "$ROOT/backups/nginx-enabled"
ln -s "$ROOT/live/etc/nginx.conf" "$ROOT/live/etc/nginx-enabled"
# Extract actual function source without evaluating preflight/deployment code.
awk '/^restore_tree\(\) \{/ {show=1} show {print} show && /^}/ {show=0}' "$SCRIPT" > "$ROOT/functions.sh"
awk '/^rollback\(\) \{/ {show=1} show {print} show && /^}/ {show=0}' "$SCRIPT" >> "$ROOT/functions.sh"
if [[ "$(grep -c '^}' "$ROOT/functions.sh")" -ne 2 ]]; then echo 'FAIL: could not extract functions' >&2; exit 1; fi
# Run the real function bodies with all system paths replaced by test directories,
# and mocked service/network commands that never touch host services.
(
  set -Eeuo pipefail
  log() { printf '%s\n' "$*"; }
  error() { printf 'ERROR: %s\n' "$*" >&2; }
  systemctl() { printf 'MOCK systemctl %s\n' "$*"; return 0; }
  nginx() { printf 'MOCK nginx %s\n' "$*"; return 0; }
  curl() { printf 'MOCK curl health request\n'; return 0; }
  userdel() { echo 'FAIL: unexpected userdel' >&2; return 1; }
  groupdel() { echo 'FAIL: unexpected groupdel' >&2; return 1; }
  source "$ROOT/functions.sh"
  APP_ROOT="$ROOT/live/app"; WEB_ROOT="$ROOT/live/web"
  BACKUP_DIR="$ROOT/backups"
  NGINX_AVAILABLE="$ROOT/live/etc/nginx.conf"
  NGINX_ENABLED="$ROOT/live/etc/nginx-enabled"
  SERVICE_DEST="$ROOT/live/etc/linux-web-api.service"
  HEALTH_URL='http://127.0.0.1:8000/health'
  PROXY_HEALTH_URL='http://127.0.0.1:8080/api/health'
  SERVICE_USER='linux-web'; SERVICE_GROUP='linux-web'
  APP_ROOT_EXISTED=1; WEB_ROOT_EXISTED=1; NGINX_CONFIG_EXISTED=1
  SERVICE_FILE_EXISTED=1; NGINX_LINK_EXISTED=1
  NGINX_WAS_ENABLED=1; SERVICE_WAS_ENABLED=1
  NGINX_WAS_ACTIVE=1; SERVICE_WAS_ACTIVE=1
  NGINX_CHANGE_ATTEMPTED=1; SERVICE_CHANGE_ATTEMPTED=1
  USER_CREATED=0; GROUP_CREATED=0
  ROLLBACK_STAGING_DIRS=()
  rollback 42
) > "$ROOT/output" 2>&1 && STATUS=0 || STATUS=$?
if [[ "$STATUS" -ne 42 ]]; then cat "$ROOT/output"; echo "FAIL: rollback returned $STATUS; expected 42"; exit 1; fi
[[ $(cat "$ROOT/live/app/app/main.py") == working ]] || { cat "$ROOT/output"; echo 'FAIL: application not restored'; exit 1; }
[[ $(cat "$ROOT/live/web/index.html") == good-page ]] || { cat "$ROOT/output"; echo 'FAIL: website not restored'; exit 1; }
[[ $(cat "$ROOT/live/etc/nginx.conf") == 'old nginx' ]] || { echo 'FAIL: nginx configuration not restored'; exit 1; }
[[ $(cat "$ROOT/live/etc/linux-web-api.service") == 'old unit' ]] || { echo 'FAIL: systemd unit not restored'; exit 1; }
if find "$ROOT/live" -type d -name '*.restore.*' | grep -q .; then echo 'FAIL: staging not cleaned'; exit 1; fi
if grep -q 'Rollback incomplete' "$ROOT/output"; then cat "$ROOT/output"; echo 'FAIL: rollback reported incomplete'; exit 1; fi
echo 'PASS: Full rollback integration with mocked system commands.'
echo 'PASS: Application, website, Nginx config, and systemd unit restored.'
echo 'PASS: Staging cleaned and original failure exit code preserved.'
echo 'NOTE: This does not test real systemd, Nginx, networking, or deployment on fresh Ubuntu.'
