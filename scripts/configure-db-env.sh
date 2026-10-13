#!/usr/bin/env bash
set -Eeuo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Run: sudo bash scripts/configure-db-env.sh"
    exit 1
fi

command -v openssl >/dev/null || {
    apt-get update
    apt-get install -y openssl
}

ENV_FILE="/etc/course-portal-api.env"
DEFAULT_HOST=""

echo "=== Course Portal environment setup ==="

read -r -p "RDS endpoint (required; no default): " DB_HOST
DB_HOST="${DB_HOST:-$DEFAULT_HOST}"

read -r -p "MySQL port [3306]: " DB_PORT
DB_PORT="${DB_PORT:-3306}"

read -r -p "Database name [courseportal]: " DB_NAME
DB_NAME="${DB_NAME:-courseportal}"

read -r -p "Database username [dbadmin]: " DB_USER
DB_USER="${DB_USER:-dbadmin}"

read -r -s -p "Database password (hidden): " DB_PASSWORD
echo

read -r -p "Admin username [admin]: " ADMIN_USERNAME
ADMIN_USERNAME="${ADMIN_USERNAME:-admin}"

read -r -s -p "Admin password (hidden): " ADMIN_PASSWORD
echo

if [[ -z "$DB_HOST" || -z "$DB_NAME" || -z "$DB_USER" ||
      -z "$DB_PASSWORD" || -z "$ADMIN_USERNAME" ||
      -z "$ADMIN_PASSWORD" ]]; then
    echo "ERROR: Required values cannot be empty."
    exit 1
fi

if ! [[ "$DB_PORT" =~ ^[0-9]+$ ]] ||
   (( DB_PORT < 1 || DB_PORT > 65535 )); then
    echo "ERROR: Invalid MySQL port."
    exit 1
fi

# Write unquoted systemd EnvironmentFile values.
# Reject whitespace, quotes, and backslashes so values remain unambiguous.
for name in DB_HOST DB_PORT DB_NAME DB_USER DB_PASSWORD ADMIN_USERNAME ADMIN_PASSWORD; do
    value="${!name}"
    case "$value" in
        *" "*|*$'\t'*|*$'\n'*|*$'\r'*|*"'"*|*'"'*|*\\*)
            echo "ERROR: $name contains unsupported whitespace, quote, or backslash."
            echo "No configuration was written."
            exit 1
            ;;
    esac
done

FLASK_SECRET_KEY="$(openssl rand -hex 32)"
COOKIE_SECURE="false"

TEMP_FILE="$(mktemp)"
trap 'rm -f "$TEMP_FILE"; unset DB_PASSWORD ADMIN_PASSWORD FLASK_SECRET_KEY' EXIT
umask 077

{
    printf 'DB_HOST=%s\n' "$DB_HOST"
    printf 'DB_PORT=%s\n' "$DB_PORT"
    printf 'DB_NAME=%s\n' "$DB_NAME"
    printf 'DB_USER=%s\n' "$DB_USER"
    printf 'DB_PASSWORD=%s\n' "$DB_PASSWORD"
    printf 'ADMIN_USERNAME=%s\n' "$ADMIN_USERNAME"
    printf 'ADMIN_PASSWORD=%s\n' "$ADMIN_PASSWORD"
    printf 'FLASK_SECRET_KEY=%s\n' "$FLASK_SECRET_KEY"
    printf 'COOKIE_SECURE=%s\n' "$COOKIE_SECURE"
} > "$TEMP_FILE"

install -o root -g root -m 0600 "$TEMP_FILE" "$ENV_FILE"

unset DB_PASSWORD ADMIN_PASSWORD FLASK_SECRET_KEY

echo
echo "Environment configured: $ENV_FILE"
echo "Owner: root:root | Permissions: 600"
echo "COOKIE_SECURE=false (HTTP demo)"
echo "Secret values were not printed."
