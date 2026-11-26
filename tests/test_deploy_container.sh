#!/usr/bin/env bash

set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

mkdir -p "$TEST_ROOT/bin"
ENV_FILE="$TEST_ROOT/deploy.env"
ACTIVE_IMAGE_FILE="$TEST_ROOT/active-image"
cat > "$ENV_FILE" <<'EOF'
APP_ENV=staging
APP_VERSION=previous
AWS_REGION=ap-south-1
API_IMAGE=123456789012.dkr.ecr.ap-south-1.amazonaws.com/linux-web-infrastructure@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
APP_VERSION=previous
EOF
printf '%s\n' '123456789012.dkr.ecr.ap-south-1.amazonaws.com/linux-web-infrastructure@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' > "$ACTIVE_IMAGE_FILE"

cat > "$TEST_ROOT/bin/docker" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "$1" == "login" ]]; then
    cat >/dev/null
    exit 0
fi
if [[ "$1" == "inspect" ]]; then
    image="$(cat "$TEST_ACTIVE_IMAGE_FILE")"
    if [[ "${SIMULATE_NEW_FAILURE:-0}" == "1" && "$image" == *"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ]]; then
        printf 'unhealthy\n'
    else
        printf 'healthy\n'
    fi
    exit 0
fi
[[ "$1" == "compose" ]] || exit 2
shift
while (($#)); do
    case "$1" in
        --env-file) shift 2 ;;
        -f) shift 2 ;;
        pull) exit 0 ;;
        up)
            image="$(awk -F= '$1 == "API_IMAGE" {sub(/^[^=]*=/, ""); print; exit}' "$TEST_ENV_FILE")"
            printf '%s\n' "$image" > "$TEST_ACTIVE_IMAGE_FILE"
            exit 0
            ;;
        ps) printf 'mock-container-id\n'; exit 0 ;;
        exec)
            image="$(cat "$TEST_ACTIVE_IMAGE_FILE")"
            if [[ "${SIMULATE_NEW_FAILURE:-0}" == "1" && "$image" == *"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ]]; then
                exit 1
            fi
            printf '{"status":"ok","service":"linux-web-api","version":"test"}\n'
            exit 0
            ;;
        *) shift ;;
    esac
done
exit 2
MOCK
chmod +x "$TEST_ROOT/bin/docker"

cat > "$TEST_ROOT/bin/aws" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'fake-ecr-token\n'
MOCK
chmod +x "$TEST_ROOT/bin/aws"

NEW_IMAGE='123456789012.dkr.ecr.ap-south-1.amazonaws.com/linux-web-infrastructure@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'

if COMPOSE_ENV_FILE="$ENV_FILE" \
    DOCKER_BIN="$TEST_ROOT/bin/docker" \
    TEST_ENV_FILE="$ENV_FILE" \
    TEST_ACTIVE_IMAGE_FILE="$ACTIVE_IMAGE_FILE" \
    PATH="$TEST_ROOT/bin:$PATH" \
    HEALTH_ATTEMPTS=1 \
    HEALTH_INTERVAL_SECONDS=0 \
    SIMULATE_NEW_FAILURE=1 \
    bash "$PROJECT_DIR/scripts/deploy-container.sh" "$NEW_IMAGE" next-release; then
    echo "FAIL: an unhealthy deployment unexpectedly succeeded" >&2
    exit 1
fi

EXPECTED_OLD='123456789012.dkr.ecr.ap-south-1.amazonaws.com/linux-web-infrastructure@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
EXPECTED_NEW='123456789012.dkr.ecr.ap-south-1.amazonaws.com/linux-web-infrastructure@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
ACTUAL_ENV="$(awk -F= '$1 == "API_IMAGE" {sub(/^[^=]*=/, ""); print; exit}' "$ENV_FILE")"
ACTUAL_VERSION="$(awk -F= '$1 == "APP_VERSION" {sub(/^[^=]*=/, ""); print; exit}' "$ENV_FILE")"
ACTUAL_ACTIVE="$(cat "$ACTIVE_IMAGE_FILE")"
[[ "$ACTUAL_ENV" == "$EXPECTED_OLD" ]] || { echo "FAIL: prior image reference was not restored" >&2; exit 1; }
[[ "$ACTUAL_VERSION" == "previous" ]] || { echo "FAIL: prior release version was not restored" >&2; exit 1; }
[[ "$ACTUAL_ACTIVE" == "$EXPECTED_OLD" ]] || { echo "FAIL: prior container image was not restored" >&2; exit 1; }
if find "$TEST_ROOT" -maxdepth 1 -name '*.rollback.*' | grep -q .; then
    echo "FAIL: successful rollback left a temporary environment backup" >&2
    exit 1
fi

echo "PASS: failed image health check restored the prior image reference and service."

if COMPOSE_ENV_FILE="$ENV_FILE" \
    DOCKER_BIN="$TEST_ROOT/bin/docker" \
    TEST_ENV_FILE="$ENV_FILE" \
    TEST_ACTIVE_IMAGE_FILE="$ACTIVE_IMAGE_FILE" \
    PATH="$TEST_ROOT/bin:$PATH" \
    HEALTH_ATTEMPTS=1 \
    HEALTH_INTERVAL_SECONDS=0 \
    SIMULATE_NEW_FAILURE=0 \
    bash "$PROJECT_DIR/scripts/deploy-container.sh" "$NEW_IMAGE" next-release; then
    :
else
    echo "FAIL: a healthy immutable release did not deploy" >&2
    exit 1
fi

[[ "$(awk -F= '$1 == "API_IMAGE" {sub(/^[^=]*=/, ""); print; exit}' "$ENV_FILE")" == "$EXPECTED_NEW" ]] || {
    echo "FAIL: healthy release image reference was not persisted" >&2
    exit 1
}
[[ "$(awk -F= '$1 == "APP_VERSION" {sub(/^[^=]*=/, ""); print; exit}' "$ENV_FILE")" == "next-release" ]] || {
    echo "FAIL: healthy release version was not persisted" >&2
    exit 1
}
[[ "$(cat "$ACTIVE_IMAGE_FILE")" == "$EXPECTED_NEW" ]] || {
    echo "FAIL: healthy release container was not activated" >&2
    exit 1
}

if COMPOSE_ENV_FILE="$ENV_FILE" \
    DOCKER_BIN="$TEST_ROOT/bin/docker" \
    TEST_ENV_FILE="$ENV_FILE" \
    TEST_ACTIVE_IMAGE_FILE="$ACTIVE_IMAGE_FILE" \
    PATH="$TEST_ROOT/bin:$PATH" \
    bash "$PROJECT_DIR/scripts/deploy-container.sh" \
    '123456789012.dkr.ecr.ap-south-1.amazonaws.com/linux-web-infrastructure:latest'; then
    echo "FAIL: mutable image tag was accepted" >&2
    exit 1
fi

echo "PASS: healthy immutable release deployed and mutable tags were rejected."
