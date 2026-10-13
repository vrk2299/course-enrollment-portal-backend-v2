import os
import re
import hmac
from contextlib import contextmanager
from datetime import timedelta
from functools import wraps

import pymysql
from pymysql.cursors import DictCursor
from flask import Flask, jsonify, request, session

app = Flask(__name__)

app.secret_key = os.environ["FLASK_SECRET_KEY"]
app.permanent_session_lifetime = timedelta(minutes=30)
app.config.update(
    SESSION_COOKIE_HTTPONLY=True,
    SESSION_COOKIE_SAMESITE="Lax",
    SESSION_COOKIE_SECURE=os.environ.get(
        "COOKIE_SECURE", "false"
    ).lower() == "true",
)

ADMIN_USERNAME = os.environ["ADMIN_USERNAME"]
ADMIN_PASSWORD = os.environ["ADMIN_PASSWORD"]

DB_CONFIG = {
    "host": os.environ["DB_HOST"],
    "port": int(os.environ.get("DB_PORT", "3306")),
    "database": os.environ.get("DB_NAME", "courseportal"),
    "user": os.environ.get("DB_USER", "dbadmin"),
    "password": os.environ["DB_PASSWORD"],
    "cursorclass": DictCursor,
    "connect_timeout": 5,
    "autocommit": True,
}

COURSES = [
    {"id": 1, "name": "AWS Cloud Foundations",
     "category": "Cloud Computing"},
    {"id": 2, "name": "Linux Administration",
     "category": "System Administration"},
    {"id": 3, "name": "DevOps Engineering",
     "category": "Automation & Delivery"},
    {"id": 4, "name": "Kubernetes Essentials",
     "category": "Container Orchestration"},
]


@contextmanager
def get_db():
    connection = pymysql.connect(**DB_CONFIG)
    try:
        yield connection
    finally:
        connection.close()


def initialize_database():
    with get_db() as connection:
        with connection.cursor() as cursor:
            cursor.execute("""
                CREATE TABLE IF NOT EXISTS enrollments (
                    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
                    name VARCHAR(120) NOT NULL,
                    email VARCHAR(254) NOT NULL,
                    course VARCHAR(120) NOT NULL,
                    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
                ) ENGINE=InnoDB
            """)

            # Safely add phone support when the configured database already has an enrollments table.
            cursor.execute("SHOW COLUMNS FROM enrollments LIKE 'phone'")
            if not cursor.fetchone():
                try:
                    cursor.execute(
                        "ALTER TABLE enrollments "
                        "ADD COLUMN phone VARCHAR(30) NULL AFTER email"
                    )
                except pymysql.err.OperationalError as exc:
                    # Another worker may have added the column concurrently.
                    if exc.args[0] != 1060:
                        raise


initialize_database()


def admin_required(function):
    @wraps(function)
    def wrapped(*args, **kwargs):
        if not session.get("admin_logged_in"):
            return jsonify({"error": "Admin login required."}), 401
        return function(*args, **kwargs)
    return wrapped


@app.get("/api/health")
def health():
    try:
        with get_db() as connection:
            with connection.cursor() as cursor:
                cursor.execute("SELECT 1")
                cursor.fetchone()
        return jsonify({
            "status": "healthy",
            "service": "course-enrollment-api",
            "database": "connected"
        })
    except Exception:
        app.logger.exception("Health check failed")
        return jsonify({
            "status": "unhealthy",
            "service": "course-enrollment-api",
            "database": "disconnected"
        }), 503


@app.get("/api/courses")
def list_courses():
    return jsonify({"courses": COURSES})


@app.post("/api/enrollments")
def create_enrollment():
    data = request.get_json(silent=True)
    if not isinstance(data, dict):
        return jsonify({"error": "Send enrollment data as JSON."}), 400

    name = str(data.get("name", "")).strip()
    email = str(data.get("email", "")).strip().lower()
    phone = str(data.get("phone", data.get("number", ""))).strip()
    course = str(data.get("course", "")).strip()

    if not name or not email or not course:
        return jsonify({
            "error": "Name, email, and course are required."
        }), 400

    if len(name) > 120 or len(email) > 254 or len(phone) > 30:
        return jsonify({"error": "A submitted field is too long."}), 400

    if not re.fullmatch(r"[^@\s]+@[^@\s]+\.[^@\s]+", email):
        return jsonify({"error": "Enter a valid email address."}), 400

    if course not in {item["name"] for item in COURSES}:
        return jsonify({"error": "Please select a valid course."}), 400

    try:
        with get_db() as connection:
            with connection.cursor() as cursor:
                cursor.execute("""
                    INSERT INTO enrollments (name, email, phone, course)
                    VALUES (%s, %s, %s, %s)
                """, (name, email, phone or None, course))
                enrollment_id = cursor.lastrowid

        return jsonify({
            "message": "Enrollment successful.",
            "enrollment": {
                "id": enrollment_id,
                "name": name,
                "email": email,
                "phone": phone,
                "course": course
            }
        }), 201
    except Exception:
        app.logger.exception("Enrollment insert failed")
        return jsonify({"error": "Unable to save enrollment."}), 500


# Never expose the full enrollment list through the old public endpoint.
@app.get("/api/enrollments")
def public_enrollments_blocked():
    return jsonify({"error": "Use the authenticated admin dashboard."}), 403


@app.post("/api/admin/login")
def admin_login():
    data = request.get_json(silent=True) or {}
    username = str(data.get("username", ""))
    password = str(data.get("password", ""))

    valid_user = hmac.compare_digest(username, ADMIN_USERNAME)
    valid_password = hmac.compare_digest(password, ADMIN_PASSWORD)

    if not (valid_user and valid_password):
        return jsonify({"error": "Invalid username or password."}), 401

    session.clear()
    session["admin_logged_in"] = True
    session.permanent = True
    return jsonify({"message": "Login successful."})


@app.get("/api/admin/me")
def admin_me():
    return jsonify({
        "authenticated": bool(session.get("admin_logged_in"))
    })


@app.post("/api/admin/logout")
@admin_required
def admin_logout():
    session.clear()
    return jsonify({"message": "Logged out."})


@app.get("/api/admin/stats")
@admin_required
def admin_stats():
    with get_db() as connection:
        with connection.cursor() as cursor:
            cursor.execute("SELECT COUNT(*) AS total FROM enrollments")
            total = cursor.fetchone()["total"]

            cursor.execute("""
                SELECT COUNT(*) AS total
                FROM enrollments
                WHERE created_at >= CURDATE()
                  AND created_at < CURDATE() + INTERVAL 1 DAY
            """)
            today = cursor.fetchone()["total"]

            cursor.execute("""
                SELECT course, COUNT(*) AS total
                FROM enrollments
                GROUP BY course
            """)
            counts = {
                row["course"]: int(row["total"])
                for row in cursor.fetchall()
            }

    return jsonify({
        "total_enrollments": int(total),
        "today_enrollments": int(today),
        "courses": [
            {
                **course,
                "enrollments": counts.get(course["name"], 0)
            }
            for course in COURSES
        ]
    })


@app.get("/api/admin/enrollments")
@admin_required
def admin_enrollments():
    search = request.args.get("q", "").strip()[:120]
    course = request.args.get("course", "").strip()

    sql = """
        SELECT id, name, email, phone, course,
               DATE_FORMAT(created_at, '%%Y-%%m-%%d %%H:%%i:%%s') AS created_at
        FROM enrollments
        WHERE 1=1
    """
    params = []

    if course:
        sql += " AND course = %s"
        params.append(course)

    if search:
        sql += """
            AND (name LIKE %s OR email LIKE %s OR phone LIKE %s)
        """
        pattern = f"%{search}%"
        params.extend([pattern, pattern, pattern])

    sql += " ORDER BY id DESC LIMIT 500"

    with get_db() as connection:
        with connection.cursor() as cursor:
            cursor.execute(sql, params)
            rows = cursor.fetchall()

    return jsonify({"enrollments": rows})


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8000)
