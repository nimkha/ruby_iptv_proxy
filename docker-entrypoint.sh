#!/bin/sh
set -e

# This script runs as root by default when the container starts.
# It prepares the environment before executing the main command (CMD)
# as the 'ruby' user (which is the default user for the ruby:slim image).

APP_DIR="/usr/src/app"
LOGS_DIR="${APP_DIR}/logs"
TMP_DIR="${APP_DIR}/tmp"
PIDS_DIR="${TMP_DIR}/pids"

# Ensure log and tmp/pids directories exist and are writable by the 'ruby' user.
# The 'ruby' user and group are standard in the official Ruby images (usually UID/GID 1000).
mkdir -p "${LOGS_DIR}" "${PIDS_DIR}"

chown -R ruby:ruby "${LOGS_DIR}"
chown -R ruby:ruby "${TMP_DIR}" # chown entire tmp for puma state and other temp files

# Execute the command passed to the entrypoint (i.e., the Dockerfile's CMD)
# This will run as the 'ruby' user due to the base image's USER directive.
exec "$@"