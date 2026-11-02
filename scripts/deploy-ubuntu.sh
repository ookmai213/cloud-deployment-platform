#!/usr/bin/env bash

set -Eeuo pipefail

# ==================================================
# Linux Web Infrastructure
# Ubuntu Deployment Script
# ==================================================

# --------------------------------------------------
# Configuration
# --------------------------------------------------

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

APP_SOURCE="$PROJECT_DIR/app"
SITE_SOURCE="$PROJECT_DIR/site"
NGINX_SOURCE="$PROJECT_DIR/deploy/nginx/linux-web-infrastructure.conf"
SERVICE_SOURCE="$PROJECT_DIR/deploy/systemd/linux-web-api.service"

APP_ROOT="/opt/linux-web-infrastructure"
APP_DIR="$APP_ROOT/app"
VENV_DIR="$APP_ROOT/.venv"
WEB_ROOT="/var/www/linux-web-infrastructure"

NGINX_AVAILABLE="/etc/nginx/sites-available/linux-web-infrastructure"
NGINX_ENABLED="/etc/nginx/sites-enabled/linux-web-infrastructure"
SERVICE_DEST="/etc/systemd/system/linux-web-api.service"

SERVICE_USER="linux-web"
SERVICE_GROUP="linux-web"

HEALTH_URL="http://127.0.0.1:8000/health"
PROXY_HEALTH_URL="http://127.0.0.1:8080/api/health"

# --------------------------------------------------
# Logging
# --------------------------------------------------

log() {
    printf '\n[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

error() {
    printf '\nERROR: %s\n' "$*" >&2
}

# --------------------------------------------------
# Root privilege check
# --------------------------------------------------

if [[ "$EUID" -ne 0 ]]; then
    error "Run this script using sudo: sudo bash scripts/deploy-ubuntu.sh"
    exit 1
fi

# --------------------------------------------------
# Prerequisites
# --------------------------------------------------

for command in \
    python3 \
    nginx \
    systemctl \
    curl \
    install \
    cmp \
    diff \
    readlink \
    groupadd \
    groupdel \
    useradd \
    userdel \
    getent \
    id \
    cut \
    chown \
    chmod \
    cp \
    rm \
    mktemp \
    date \
    find \
    runuser \
    ln \
    dirname \
    env
do
    if ! command -v "$command" >/dev/null 2>&1; then
        error "Required command not found: $command"
        exit 1
    fi
done

if ! python3 -m venv --help >/dev/null 2>&1; then
    error "Python virtual environment support is unavailable."
    error "Install the Ubuntu python3-venv package."
    exit 1
fi

# --------------------------------------------------
# Validate deployment source
# --------------------------------------------------

log "Checking deployment source files"

for file in \
    "$APP_SOURCE/main.py" \
    "$APP_SOURCE/requirements.txt" \
    "$SITE_SOURCE/index.html" \
    "$NGINX_SOURCE" \
    "$SERVICE_SOURCE"
do
    if [[ ! -f "$file" ]]; then
        error "Required source file missing: $file"
        exit 1
    fi
done

# Refuse to replace symlinked deployment directories. This protects
# the fixed paths used by the backup and restore operations below.
for directory in "$APP_ROOT" "$APP_DIR" "$VENV_DIR" "$WEB_ROOT"; do
    if [[ -L "$directory" ]]; then
        error "Refusing to deploy because this path is a symbolic link: $directory"
        exit 1
    fi
done

# --------------------------------------------------
# Record previous service states
# --------------------------------------------------

NGINX_WAS_ENABLED=0
SERVICE_WAS_ENABLED=0
NGINX_WAS_ACTIVE=0
SERVICE_WAS_ACTIVE=0

if systemctl is-enabled --quiet nginx; then
    NGINX_WAS_ENABLED=1
fi

if systemctl is-enabled --quiet linux-web-api; then
    SERVICE_WAS_ENABLED=1
fi

if systemctl is-active --quiet nginx; then
    NGINX_WAS_ACTIVE=1
fi

if systemctl is-active --quiet linux-web-api; then
    SERVICE_WAS_ACTIVE=1
fi

# --------------------------------------------------
# Create backup before changing the system
# --------------------------------------------------

if [[ ! -d /var/backups ]]; then
    error "/var/backups does not exist. Create it before deployment."
    exit 1
fi

BACKUP_DIR="$(mktemp -d /var/backups/linux-web-deploy.XXXXXX)"
chmod 700 "$BACKUP_DIR"

APP_ROOT_EXISTED=0
WEB_ROOT_EXISTED=0
NGINX_CONFIG_EXISTED=0
SERVICE_FILE_EXISTED=0
NGINX_LINK_EXISTED=0

# Back up the complete deployment root in one operation. This preserves
# the app, virtual environment, ownership, permissions, and any other files.
if [[ -d "$APP_ROOT" ]]; then
    APP_ROOT_EXISTED=1
    cp -a "$APP_ROOT" "$BACKUP_DIR/app-root"
fi

if [[ -d "$WEB_ROOT" ]]; then
    WEB_ROOT_EXISTED=1
    cp -a "$WEB_ROOT" "$BACKUP_DIR/website"
fi

if [[ -f "$NGINX_AVAILABLE" ]]; then
    NGINX_CONFIG_EXISTED=1
    cp -a "$NGINX_AVAILABLE" "$BACKUP_DIR/nginx.conf"
elif [[ -e "$NGINX_AVAILABLE" || -L "$NGINX_AVAILABLE" ]]; then
    error "Unexpected non-file at $NGINX_AVAILABLE"
    exit 1
fi

if [[ -f "$SERVICE_DEST" ]]; then
    SERVICE_FILE_EXISTED=1
    cp -a "$SERVICE_DEST" "$BACKUP_DIR/linux-web-api.service"
elif [[ -e "$SERVICE_DEST" || -L "$SERVICE_DEST" ]]; then
    error "Unexpected non-file at $SERVICE_DEST"
    exit 1
fi

if [[ -e "$NGINX_ENABLED" || -L "$NGINX_ENABLED" ]]; then
    NGINX_LINK_EXISTED=1
    cp -a "$NGINX_ENABLED" "$BACKUP_DIR/nginx-enabled"
fi

# --------------------------------------------------
# Transaction state and rollback
# --------------------------------------------------

GROUP_CREATED=0
USER_CREATED=0
NGINX_CHANGE_ATTEMPTED=0
SERVICE_CHANGE_ATTEMPTED=0

rollback() {
    local failure_code="$1"
    local rollback_failed=0

    # Disable traps so an error during recovery cannot recurse.
    trap - ERR INT TERM HUP
    set +e

    error "Deployment failed. Attempting rollback."

    # Restore the complete deployment root, including app and virtualenv.
    if [[ "$APP_ROOT_EXISTED" -eq 1 ]]; then
        rm -rf "$APP_ROOT"
        if ! cp -a "$BACKUP_DIR/app-root" "$APP_ROOT"; then
            error "Could not restore deployment root."
            rollback_failed=1
        fi
    else
        if ! rm -rf "$APP_ROOT"; then
            error "Could not remove newly-created deployment root."
            rollback_failed=1
        fi
    fi

    # Restore static website.
    if [[ "$WEB_ROOT_EXISTED" -eq 1 ]]; then
        rm -rf "$WEB_ROOT"
        if ! cp -a "$BACKUP_DIR/website" "$WEB_ROOT"; then
            error "Could not restore static website."
            rollback_failed=1
        fi
    else
        if ! rm -rf "$WEB_ROOT"; then
            error "Could not remove newly-created website directory."
            rollback_failed=1
        fi
    fi

    # Restore Nginx site configuration.
    if [[ "$NGINX_CONFIG_EXISTED" -eq 1 ]]; then
        if ! cp -a "$BACKUP_DIR/nginx.conf" "$NGINX_AVAILABLE"; then
            error "Could not restore Nginx configuration."
            rollback_failed=1
        fi
    else
        if ! rm -f "$NGINX_AVAILABLE"; then
            error "Could not remove newly-created Nginx configuration."
            rollback_failed=1
        fi
    fi

    # Restore the Nginx enabled-site entry.
    if ! rm -f "$NGINX_ENABLED"; then
        error "Could not remove current Nginx enabled-site entry."
        rollback_failed=1
    fi

    if [[ "$NGINX_LINK_EXISTED" -eq 1 ]]; then
        if ! cp -a "$BACKUP_DIR/nginx-enabled" "$NGINX_ENABLED"; then
            error "Could not restore previous Nginx enabled-site entry."
            rollback_failed=1
        fi
    fi

    # If this deployment created and attempted to start the API unit,
    # stop it while systemd can still resolve the unit definition.
    if [[ "$SERVICE_FILE_EXISTED" -eq 0 && "$SERVICE_CHANGE_ATTEMPTED" -eq 1 ]]; then
        systemctl stop linux-web-api || { error "Could not stop deployment-created API unit."; rollback_failed=1; }
    fi

    # If this deployment created the API unit, remove any enablement link
    # before deleting the unit file. This avoids leaving a dangling wants link.
    if [[ "$SERVICE_FILE_EXISTED" -eq 0 && -f "$SERVICE_DEST" ]]; then
        systemctl disable linux-web-api || { error "Could not disable deployment-created API unit."; rollback_failed=1; }
    fi

    # Restore systemd unit file and reload systemd's unit cache.
    if [[ "$SERVICE_FILE_EXISTED" -eq 1 ]]; then
        if ! cp -a "$BACKUP_DIR/linux-web-api.service" "$SERVICE_DEST"; then
            error "Could not restore systemd service file."
            rollback_failed=1
        fi
    else
        if ! rm -f "$SERVICE_DEST"; then
            error "Could not remove newly-created systemd service file."
            rollback_failed=1
        fi
    fi

    if ! systemctl daemon-reload; then
        error "systemctl daemon-reload failed during rollback."
        rollback_failed=1
    fi

    # Restore enablement state. Nginx's unit is provided by the OS.
    if [[ "$NGINX_WAS_ENABLED" -eq 1 ]]; then
        systemctl enable nginx || { error "Could not restore Nginx enablement."; rollback_failed=1; }
    else
        systemctl disable nginx || { error "Could not restore Nginx disabled state."; rollback_failed=1; }
    fi

    # Only change the API enablement state if its unit existed before
    # deployment or the deployment-created unit is still present.
    if [[ "$SERVICE_FILE_EXISTED" -eq 1 ]]; then
        if [[ "$SERVICE_WAS_ENABLED" -eq 1 ]]; then
            systemctl enable linux-web-api || { error "Could not restore API enablement."; rollback_failed=1; }
        else
            systemctl disable linux-web-api || { error "Could not restore API disabled state."; rollback_failed=1; }
        fi
    fi

    # Restore runtime state only if a start/reload/restart was attempted.
    if [[ "$NGINX_CHANGE_ATTEMPTED" -eq 1 ]]; then
        if [[ "$NGINX_WAS_ACTIVE" -eq 1 ]]; then
            if nginx -t; then
                systemctl restart nginx || { error "Could not restart Nginx after rollback."; rollback_failed=1; }
            else
                error "Restored Nginx configuration failed validation; Nginx was not restarted."
                rollback_failed=1
            fi
        else
            systemctl stop nginx || { error "Could not restore Nginx inactive state."; rollback_failed=1; }
        fi
    fi

    if [[ "$SERVICE_CHANGE_ATTEMPTED" -eq 1 && "$SERVICE_FILE_EXISTED" -eq 1 ]]; then
        if [[ "$SERVICE_WAS_ACTIVE" -eq 1 ]]; then
            systemctl restart linux-web-api || { error "Could not restart API after rollback."; rollback_failed=1; }
        else
            systemctl stop linux-web-api || { error "Could not restore API inactive state."; rollback_failed=1; }
        fi
    fi

    # Remove only identities created by this deployment. Do this after
    # attempting to stop services and restore their previous state.
    if [[ "$USER_CREATED" -eq 1 ]]; then
        userdel "$SERVICE_USER" || { error "Could not remove newly-created service user."; rollback_failed=1; }
    fi

    if [[ "$GROUP_CREATED" -eq 1 ]]; then
        groupdel "$SERVICE_GROUP" || { error "Could not remove newly-created service group."; rollback_failed=1; }
    fi

    if [[ "$rollback_failed" -eq 0 ]]; then
        log "Rollback operations completed. Verify service health manually."
    else
        error "Rollback was incomplete. Manual recovery is required."
    fi

    echo "Backup retained at: $BACKUP_DIR"
    exit "$failure_code"
}

trap 'rollback "$?"' ERR
trap 'rollback 130' INT
trap 'rollback 143' TERM
trap 'rollback 129' HUP

# --------------------------------------------------
# Create and validate service account
# --------------------------------------------------

log "Checking service account"

if ! getent group "$SERVICE_GROUP" >/dev/null; then
    groupadd --system "$SERVICE_GROUP"
    GROUP_CREATED=1
    log "Created group: $SERVICE_GROUP"
fi

if ! id "$SERVICE_USER" >/dev/null 2>&1; then
    useradd \
        --system \
        --gid "$SERVICE_GROUP" \
        --home-dir /nonexistent \
        --no-create-home \
        --shell /usr/sbin/nologin \
        "$SERVICE_USER"
    USER_CREATED=1
    log "Created user: $SERVICE_USER"
fi

ACTUAL_GROUP="$(id -gn "$SERVICE_USER")"
PASSWD_ENTRY="$(getent passwd "$SERVICE_USER")"
ACTUAL_HOME="$(printf '%s\n' "$PASSWD_ENTRY" | cut -d: -f6)"
ACTUAL_SHELL="$(printf '%s\n' "$PASSWD_ENTRY" | cut -d: -f7)"

if [[ "$ACTUAL_GROUP" != "$SERVICE_GROUP" ]]; then
    error "Unexpected primary group for $SERVICE_USER: $ACTUAL_GROUP"
    false
fi

if [[ "$ACTUAL_HOME" != "/nonexistent" ]]; then
    error "Unexpected home directory for $SERVICE_USER: $ACTUAL_HOME"
    false
fi

if [[ "$ACTUAL_SHELL" != "/usr/sbin/nologin" ]]; then
    error "Unexpected login shell for $SERVICE_USER: $ACTUAL_SHELL"
    false
fi

# --------------------------------------------------
# Prepare deployment directories
# --------------------------------------------------

log "Preparing deployment directories"

install -d -o root -g "$SERVICE_GROUP" -m 750 "$APP_ROOT"
install -d -o root -g "$SERVICE_GROUP" -m 750 "$APP_DIR"
install -d -o root -g root -m 755 "$WEB_ROOT"

# --------------------------------------------------
# Deploy application files
# --------------------------------------------------

APP_CHANGED=0
DEPENDENCIES_CHANGED=0

log "Deploying application source"

for file in main.py requirements.txt; do
    source_file="$APP_SOURCE/$file"
    destination_file="$APP_DIR/$file"

    if ! cmp -s "$source_file" "$destination_file"; then
        install \
            -o root \
            -g "$SERVICE_GROUP" \
            -m 640 \
            "$source_file" \
            "$destination_file"

        if [[ "$file" == "requirements.txt" ]]; then
            DEPENDENCIES_CHANGED=1
        else
            APP_CHANGED=1
        fi

        log "Updated application file: $file"
    fi
done

# --------------------------------------------------
# Prepare production virtual environment
# --------------------------------------------------

VENV_CREATED=0

if [[ ! -x "$VENV_DIR/bin/python" ]]; then
    python3 -m venv "$VENV_DIR"
    VENV_CREATED=1
    log "Created production virtual environment"
fi

# --------------------------------------------------
# Install dependencies when required
# --------------------------------------------------

if [[ "$VENV_CREATED" -eq 1 || "$DEPENDENCIES_CHANGED" -eq 1 ]]; then
    log "Installing Python dependencies"

    "$VENV_DIR/bin/python" -m pip install \
        --disable-pip-version-check \
        --no-cache-dir \
        -r "$APP_DIR/requirements.txt"

    APP_CHANGED=1
fi

# Ensure the service group can traverse and read the production venv.
chown -R "root:$SERVICE_GROUP" "$VENV_DIR"

# --------------------------------------------------
# Validate application import as service user
# --------------------------------------------------

log "Validating application import as $SERVICE_USER"

runuser -u "$SERVICE_USER" -- \
    env PYTHONPATH="$APP_DIR" \
    "$VENV_DIR/bin/python" \
    -c 'import main; print("Application import successful")'

# --------------------------------------------------
# Deploy static website only when content differs
# --------------------------------------------------

log "Checking static website"

if ! diff -qr "$SITE_SOURCE" "$WEB_ROOT" >/dev/null 2>&1; then
    find "$WEB_ROOT" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
    cp -a "$SITE_SOURCE/." "$WEB_ROOT/"

    chown -R root:root "$WEB_ROOT"
    log "Static website updated"
fi

# Enforce web-readable ownership and permissions on every deployment.
chown -R root:root "$WEB_ROOT"
find "$WEB_ROOT" -type d -exec chmod 755 {} +
find "$WEB_ROOT" -type f -exec chmod 644 {} +

# --------------------------------------------------
# Deploy systemd service definition
# --------------------------------------------------

SERVICE_CHANGED=0

if ! cmp -s "$SERVICE_SOURCE" "$SERVICE_DEST"; then
    install \
        -o root \
        -g root \
        -m 644 \
        "$SERVICE_SOURCE" \
        "$SERVICE_DEST"

    SERVICE_CHANGED=1
    log "Systemd service definition updated"
    systemctl daemon-reload
fi

UNIT_LOAD_STATE="$(systemctl show linux-web-api --property=LoadState --value)"
if [[ "$UNIT_LOAD_STATE" != "loaded" ]]; then
    error "systemd did not load linux-web-api correctly (LoadState=$UNIT_LOAD_STATE)."
    false
fi

# --------------------------------------------------
# Deploy Nginx configuration and enabled-site link
# --------------------------------------------------

NGINX_CHANGED=0

if ! cmp -s "$NGINX_SOURCE" "$NGINX_AVAILABLE"; then
    install \
        -o root \
        -g root \
        -m 644 \
        "$NGINX_SOURCE" \
        "$NGINX_AVAILABLE"

    NGINX_CHANGED=1
    log "Nginx configuration updated"
fi

if [[ ! -L "$NGINX_ENABLED" ]] || \
   [[ "$(readlink -f "$NGINX_ENABLED" 2>/dev/null || true)" != "$NGINX_AVAILABLE" ]]; then
    ln -sfn "$NGINX_AVAILABLE" "$NGINX_ENABLED"
    NGINX_CHANGED=1
    log "Nginx enabled-site link updated"
fi

# --------------------------------------------------
# Validate Nginx configuration
# --------------------------------------------------

log "Validating Nginx configuration"
nginx -t

# --------------------------------------------------
# Enable services
# --------------------------------------------------

systemctl enable nginx linux-web-api

# --------------------------------------------------
# Reload or start Nginx
# --------------------------------------------------

if [[ "$NGINX_CHANGED" -eq 1 ]]; then
    NGINX_CHANGE_ATTEMPTED=1

    if [[ "$NGINX_WAS_ACTIVE" -eq 1 ]]; then
        systemctl reload nginx
    else
        systemctl start nginx
    fi
elif [[ "$NGINX_WAS_ACTIVE" -eq 0 ]]; then
    NGINX_CHANGE_ATTEMPTED=1
    systemctl start nginx
fi

# --------------------------------------------------
# Restart or start FastAPI
# --------------------------------------------------

if [[ "$APP_CHANGED" -eq 1 || "$SERVICE_CHANGED" -eq 1 ]]; then
    SERVICE_CHANGE_ATTEMPTED=1

    if [[ "$SERVICE_WAS_ACTIVE" -eq 1 ]]; then
        systemctl restart linux-web-api
    else
        systemctl start linux-web-api
    fi
elif [[ "$SERVICE_WAS_ACTIVE" -eq 0 ]]; then
    SERVICE_CHANGE_ATTEMPTED=1
    systemctl start linux-web-api
fi

# --------------------------------------------------
# Validate service state
# --------------------------------------------------

log "Checking service status"
systemctl is-active --quiet nginx
systemctl is-active --quiet linux-web-api

# --------------------------------------------------
# Direct API health check
# --------------------------------------------------

log "Checking FastAPI health endpoint"
curl \
    --fail \
    --silent \
    --show-error \
    --retry 5 \
    --retry-delay 2 \
    --retry-connrefused \
    "$HEALTH_URL"
printf '\n'

# --------------------------------------------------
# Nginx reverse-proxy health check
# --------------------------------------------------

log "Checking Nginx reverse-proxy health endpoint"
curl \
    --fail \
    --silent \
    --show-error \
    --retry 5 \
    --retry-delay 2 \
    --retry-connrefused \
    "$PROXY_HEALTH_URL"
printf '\n'

# --------------------------------------------------
# Deployment complete
# --------------------------------------------------

trap - ERR INT TERM HUP

log "Ubuntu deployment completed successfully"
printf 'Nginx: active\n'
printf 'FastAPI: active\n'
printf 'Application health: passed\n'
printf 'Nginx proxy health: passed\n'
printf 'Rollback backup retained at: %s\n' "$BACKUP_DIR"
