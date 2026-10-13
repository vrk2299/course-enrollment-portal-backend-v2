#!/bin/bash
sudo systemctl status course-portal-api --no-pager
curl -i http://127.0.0.1:8000/api/health
curl -i http://127.0.0.1:8000/api/courses
