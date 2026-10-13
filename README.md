# Course Enrollment Portal — Backend

Flask REST API for the Course Enrollment Portal.

## Application layout

- `app/main.py` — Flask application and WSGI object `app`.
- `requirements.txt` — dependency ranges for general/manual development.
- `requirements.lock` — pinned dependencies used by the Golden AMI build when present.
- `scripts/` and `systemd/` — legacy/manual EC2 demo setup helpers.

## Runtime configuration

The app reads configuration from environment variables; it does not hardcode an RDS endpoint in `app/main.py`:

- `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD`
- `FLASK_SECRET_KEY`, `ADMIN_USERNAME`, `ADMIN_PASSWORD`, `COOKIE_SECURE`

For the Terraform/Golden AMI architecture, the infrastructure repository builds an image with Packer. Terraform injects the new RDS endpoint and secret ARNs at instance launch. The EC2 instance role retrieves credentials from AWS Secrets Manager. Do not put runtime values into the AMI.

## Golden AMI deployment

Use the `packer/` configuration in the infrastructure repository. It accepts this repository's current layout (`app/main.py`) and stages the Flask entry point as `/opt/course-portal-api/main.py` inside the image, matching the `main:app` Gunicorn target used by the existing systemd setup.

The backend source must be available through public HTTPS for the current Packer template. The Packer template defaults to branch `master` based on the uploaded repository archive name; change the branch variable if the GitHub repository's actual default branch differs.

## Legacy/manual demo setup

For the earlier single-EC2 demo only:

1. Configure `/etc/course-portal-api.env` with `sudo bash scripts/configure-db-env.sh`.
2. The script now requires an explicit RDS endpoint and no longer defaults to the old lab database.
3. Run `sudo bash scripts/setup.sh`.

These manual scripts are not the normal deployment path for the Terraform ASG. Never commit actual environment files, passwords, session keys, private keys, or database dumps.
