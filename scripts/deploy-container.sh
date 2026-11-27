#!/usr/bin/env bash

set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${COMPOSE_ENV_FILE:-$PROJECT_DIR/.env}"
DOCKER_BIN="${DOCKER_BIN:-docker}"
HEALTH_ATTEMPTS="${HEALTH_ATTEMPTS:-30}"
HEALTH_INTERVAL_SECONDS="${HEALTH_INTERVAL_SECONDS:-2}"
DOCKER_AUTH_DIR=""

error() {
    printf 'ERROR: %s\n' "$*" >&2
}

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

cleanup() {
    if [[ -n "$DOCKER_AUTH_DIR" && -d "$DOCKER_AUTH_DIR" ]]; then
        rm -rf -- "$DOCKER_AUTH_DIR"
    fi
}
trap cleanup EXIT

if [[ "$#" -lt 1 || "$#" -gt 2 ]]; then
    error "Usage: $0 <registry/repository@sha256:digest> [release-version]"
    exit 2
fi

NEW_IMAGE="$1"
IMAGE_DIGEST="${NEW_IMAGE##*@sha256:}"
NEW_VERSION="${2:-sha256-${IMAGE_DIGEST:0:12}}"
if [[ ! "$NEW_IMAGE" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*(\:[0-9]+)?/[A-Za-z0-9._/-]+@sha256:[a-f0-9]{64}$ ]]; then
    error "Image must be an immutable registry reference ending in @sha256:<64 lowercase hex characters>."
    exit 2
fi

if [[ ! "$NEW_VERSION" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$ ]]; then
    error "Release version must contain only safe version characters and be at most 64 characters."
    exit 2
fi

if [[ ! "$HEALTH_ATTEMPTS" =~ ^[1-9][0-9]*$ || ! "$HEALTH_INTERVAL_SECONDS" =~ ^[0-9]+$ ]]; then
    error "Health-check retry settings must be non-negative integers, with at least one attempt."
    exit 2
fi

if [[ ! -f "$ENV_FILE" || -L "$ENV_FILE" ]]; then
    error "Expected a regular Compose environment file: $ENV_FILE"
    exit 1
fi

COMPOSE=(
    "$DOCKER_BIN" compose
    --env-file "$ENV_FILE"
    -f "$PROJECT_DIR/compose.yaml"
    -f "$PROJECT_DIR/compose.cloud.yaml"
)

read_env_value() {
    local key="$1"
    awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$ENV_FILE"
}

write_release() {
    local image="$1" version="$2"
    local mode tmp

    mode="$(stat -c '%a' "$ENV_FILE")"
    tmp="$(mktemp "${ENV_FILE}.tmp.XXXXXX")"
    if ! awk -F= -v image="$image" -v version="$version" '
        BEGIN { found_image = 0; found_version = 0 }
        $1 == "API_IMAGE" {
            if (!found_image) print "API_IMAGE=" image
            found_image = 1
            next
        }
        $1 == "APP_VERSION" {
            if (!found_version) print "APP_VERSION=" version
            found_version = 1
            next
        }
        { print }
        END {
            if (!found_image) print "API_IMAGE=" image
            if (!found_version) print "APP_VERSION=" version
        }
    ' "$ENV_FILE" > "$tmp"; then
        rm -f -- "$tmp"
        return 1
    fi
    if ! chmod "$mode" "$tmp" || ! mv -f -- "$tmp" "$ENV_FILE"; then
        rm -f -- "$tmp"
        return 1
    fi
}

wait_healthy() {
    local service="$1"
    local attempt container_id status

    for ((attempt = 1; attempt <= HEALTH_ATTEMPTS; attempt++)); do
        container_id="$("${COMPOSE[@]}" ps -q "$service" 2>/dev/null || true)"
        if [[ -n "$container_id" ]]; then
            status="$("$DOCKER_BIN" inspect --format '{{.State.Health.Status}}' "$container_id" 2>/dev/null || true)"
            if [[ "$status" == "healthy" ]]; then
                return 0
            fi
            if [[ "$status" == "unhealthy" ]]; then
                return 1
            fi
        fi
        sleep "$HEALTH_INTERVAL_SECONDS"
    done
    return 1
}

smoke_test() {
    local body
    body="$("${COMPOSE[@]}" exec -T nginx wget -qO- http://127.0.0.1:8080/healthz)" || return 1
    [[ "$body" == *'"status":"ok"'* ]]
}

OLD_IMAGE="$(read_env_value API_IMAGE)"
OLD_VERSION="$(read_env_value APP_VERSION)"
if [[ "$OLD_IMAGE" == "$NEW_IMAGE" && "$OLD_VERSION" == "$NEW_VERSION" ]]; then
    if wait_healthy api && wait_healthy nginx && smoke_test; then
        log "Release unchanged; existing API and Nginx health checks passed."
        exit 0
    fi
    error "The configured image is unchanged, but deployment health checks failed."
    exit 1
fi

BACKUP_ENV="$(mktemp "${ENV_FILE}.rollback.XXXXXX")"
cp -p -- "$ENV_FILE" "$BACKUP_ENV"

REGISTRY="${NEW_IMAGE%%/*}"
if [[ "$REGISTRY" == *.dkr.ecr.*.amazonaws.com ]]; then
    AWS_REGION="$(read_env_value AWS_REGION)"
    if [[ -z "$AWS_REGION" ]] || ! command -v aws >/dev/null 2>&1; then
        rm -f -- "$BACKUP_ENV"
        error "AWS_REGION and the AWS CLI are required to authenticate to ECR."
        exit 1
    fi
    DOCKER_AUTH_DIR="$(mktemp -d "${TMPDIR:-/tmp}/linux-web-docker-config.XXXXXX")"
    chmod 700 "$DOCKER_AUTH_DIR"
    export DOCKER_CONFIG="$DOCKER_AUTH_DIR"
    if ! aws ecr get-login-password --region "$AWS_REGION" |
        "$DOCKER_BIN" login --username AWS --password-stdin "$REGISTRY"; then
        rm -f -- "$BACKUP_ENV"
        error "Could not authenticate to ECR; no application files were changed."
        exit 1
    fi
fi

log "Deploying immutable image $NEW_IMAGE (version $NEW_VERSION)"
if ! write_release "$NEW_IMAGE" "$NEW_VERSION" ||
   ! "${COMPOSE[@]}" pull api ||
   ! "${COMPOSE[@]}" up -d --no-build api ||
   ! wait_healthy api ||
   ! "${COMPOSE[@]}" up -d --no-build --no-deps --force-recreate nginx ||
   ! wait_healthy nginx ||
   ! smoke_test; then
    error "New deployment failed validation; restoring the previous image reference."
    cp -p -- "$BACKUP_ENV" "$ENV_FILE"

    if [[ -n "$OLD_IMAGE" ]]; then
        if "${COMPOSE[@]}" pull api &&
           "${COMPOSE[@]}" up -d --no-build api &&
           wait_healthy api &&
           "${COMPOSE[@]}" up -d --no-build --no-deps --force-recreate nginx &&
           wait_healthy nginx &&
           smoke_test; then
            rm -f -- "$BACKUP_ENV"
            log "Rollback to $OLD_IMAGE passed container health and proxy smoke checks."
        else
            error "Rollback validation failed. Preserve the environment backup at $BACKUP_ENV and recover manually."
            exit 1
        fi
    else
        error "No previous image was recorded. This first deployment cannot roll back automatically."
        rm -f -- "$BACKUP_ENV"
        exit 1
    fi
    exit 1
fi

rm -f -- "$BACKUP_ENV"
log "New deployment passed API and Nginx health checks."
