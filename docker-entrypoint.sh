#!/bin/sh
set -e

# This script runs as root by default when the container starts.
# It prepares the environment before executing the main command (CMD)
# as the 'ruby' user (which is the default user for the ruby:slim image).

APP_USER_UID=1000  # Standard UID for 'ruby' user in official Ruby images
APP_USER_GID=1000  # Standard GID for 'ruby' group in official Ruby images

APP_DIR="/usr/src/app"
LOGS_DIR="${APP_DIR}/logs"
TMP_DIR="${APP_DIR}/tmp"
PIDS_DIR="${TMP_DIR}/pids"

# Ensure log and tmp/pids directories exist and are writable by the 'ruby' user.
# These directories are created by 'RUN mkdir -p logs tmp/pids' in Dockerfile as root.
# We need to ensure they are writable by the application user.
echo "Entrypoint: Ensuring directories and permissions..."
echo "LOGS_DIR: ${LOGS_DIR}"
echo "TMP_DIR: ${TMP_DIR}"

mkdir -p "${LOGS_DIR}" "${PIDS_DIR}"

echo "Changing ownership of ${LOGS_DIR} to UID:GID ${APP_USER_UID}:${APP_USER_GID}"
chown -R "${APP_USER_UID}:${APP_USER_GID}" "${LOGS_DIR}"

echo "Changing ownership of ${TMP_DIR} to UID:GID ${APP_USER_UID}:${APP_USER_GID}"
chown -R "${APP_USER_UID}:${APP_USER_GID}" "${TMP_DIR}"

# Execute the command passed to the entrypoint (i.e., the Dockerfile's CMD)
echo "Executing command as UID ${APP_USER_UID}: $@"
exec gosu "${APP_USER_UID}" "$@"