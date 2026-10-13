#!/usr/bin/env bash
set -Eeuo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Run: sudo bash scripts/setup.sh"
    exit 1
fi

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="/opt/course-portal-api"
SERVICE="course-portal-api"
ENV_FILE="/etc/course-portal-api.env"

echo "=== 1. Validate required files ==="
for file in "$REPO/app/main.py" "$REPO/requirements.txt"; do
    if [ ! -f "$file" ]; then
        echo "ERROR: Missing $file"
        exit 1
    fi
done

if [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: Environment file missing."
    echo "Run: sudo bash scripts/configure-db-env.sh"
    exit 1
fi

for key in DB_HOST DB_PORT DB_NAME DB_USER DB_PASSWORD \
           ADMIN_USERNAME ADMIN_PASSWORD FLASK_SECRET_KEY COOKIE_SECURE; do
    if ! grep -q "^${key}=" "$ENV_FILE"; then
        echo "ERROR: Missing $key in environment file."
        exit 1
    fi
done

chmod 600 "$ENV_FILE"
chown root:root "$ENV_FILE"

echo "=== 2. Install operating-system packages ==="
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    python3 python3-venv python3-pip python3-dev \
    build-essential git curl ca-certificates

echo "=== 3. Prepare application directories ==="
install -d -o ubuntu -g ubuntu -m 0755 "$APP"
install -d -o ubuntu -g ubuntu -m 0750 /var/lib/course-portal

echo "=== 4. Deploy application source ==="
install -o ubuntu -g ubuntu -m 0644 \
    "$REPO/app/main.py" "$APP/main.py"

install -o ubuntu -g ubuntu -m 0644 \
    "$REPO/requirements.txt" "$APP/requirements.txt"

echo "=== 5. Create Python virtual environment ==="
if [ ! -x "$APP/.venv/bin/python" ]; then
    runuser -u ubuntu -- python3 -m venv "$APP/.venv"
fi

echo "=== 6. Install application dependencies ==="
if [ -f "$REPO/requirements.lock" ]; then
    install -o ubuntu -g ubuntu -m 0644 "$REPO/requirements.lock" "$APP/requirements.lock"
    REQUIREMENTS_FILE="$APP/requirements.lock"
else
    REQUIREMENTS_FILE="$APP/requirements.txt"
fi
runuser -u ubuntu -- "$APP/.venv/bin/python" -m pip install \
    -r "$REQUIREMENTS_FILE"

echo "=== 7. Verify Python imports ==="
runuser -u ubuntu -- "$APP/.venv/bin/python" -c \
    'import flask, gunicorn, pymysql; print("Flask, Gunicorn and PyMySQL OK")'

echo "=== 8. Install systemd service ==="
cat > "/etc/systemd/system/${SERVICE}.service" <<'EOF'
[Unit]
Description=Course Enrollment Portal Flask API
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=ubuntu
Group=ubuntu
WorkingDirectory=/opt/course-portal-api
EnvironmentFile=/etc/course-portal-api.env
Environment=DATA_DIR=/var/lib/course-portal
ExecStart=/opt/course-portal-api/.venv/bin/gunicorn --workers 2 --bind 0.0.0.0:8000 main:app
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "$SERVICE"

echo "=== 9. Start the API ==="
systemctl restart "$SERVICE"
sleep 3

if ! systemctl is-active --quiet "$SERVICE"; then
    echo "ERROR: API service failed to start."
    journalctl -u "$SERVICE" -n 80 --no-pager
    exit 1
fi

echo "=== 10. Test health endpoint ==="
if ! curl --fail --silent --show-error --max-time 10 \
    http://127.0.0.1:8000/api/health; then
    echo
    echo "Health check failed. Recent logs:"
    journalctl -u "$SERVICE" -n 80 --no-pager
    exit 1
fi

echo
echo "=== 11. Test courses endpoint ==="
if ! curl --fail --silent --show-error --max-time 10 \
    http://127.0.0.1:8000/api/courses; then
    echo
    echo "Courses check failed. Recent logs:"
    journalctl -u "$SERVICE" -n 80 --no-pager
    exit 1
fi

echo
echo "=== BACKEND DEPLOYMENT SUCCESSFUL ==="
systemctl --no-pager --full status "$SERVICE"
