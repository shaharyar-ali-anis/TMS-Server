#!/usr/bin/env bash
# backup_traffic_data.sh
# Dumps traffic_data from the running mongodb container before the image-URL migration.
# Safe to re-run; each run is timestamped, nothing is overwritten.

set -euo pipefail

CONTAINER="mongodb"
MONGO_USER="admin"
MONGO_PASS="admin6754"
DB_NAME="traffic_data"
BACKUP_DIR="/opt/hazen-stack/backups"
TS="$(date +%Y%m%d_%H%M%S)"
ARCHIVE_NAME="traffic_data_pre_urlfix_${TS}.agz"
CONTAINER_TMP="/tmp/${ARCHIVE_NAME}"

echo "==> Checking container '${CONTAINER}' is running"
if ! sudo docker ps --format '{{.Names}}' | grep -qx "${CONTAINER}"; then
  echo "ERROR: container '${CONTAINER}' is not running. Aborting." >&2
  exit 1
fi

echo "==> Ensuring backup dir exists: ${BACKUP_DIR}"
sudo mkdir -p "${BACKUP_DIR}"

echo "==> Running mongodump inside ${CONTAINER} for db '${DB_NAME}'"
sudo docker exec "${CONTAINER}" sh -c \
  "mongodump --uri=\"mongodb://${MONGO_USER}:${MONGO_PASS}@localhost:27017/?authSource=admin\" \
     --db=${DB_NAME} --gzip --archive=${CONTAINER_TMP}"

echo "==> Copying archive out of container to host"
sudo docker cp "${CONTAINER}:${CONTAINER_TMP}" "${BACKUP_DIR}/${ARCHIVE_NAME}"

echo "==> Removing archive from inside the container"
sudo docker exec "${CONTAINER}" rm -f "${CONTAINER_TMP}"

echo "==> Verifying backup on host"
if [ ! -s "${BACKUP_DIR}/${ARCHIVE_NAME}" ]; then
  echo "ERROR: backup file missing or zero bytes: ${BACKUP_DIR}/${ARCHIVE_NAME}" >&2
  exit 1
fi

ls -lh "${BACKUP_DIR}/${ARCHIVE_NAME}"
echo "==> Backup OK: ${BACKUP_DIR}/${ARCHIVE_NAME}"
echo "==> Rollback command (if ever needed):"
echo "    sudo docker cp ${BACKUP_DIR}/${ARCHIVE_NAME} ${CONTAINER}:/tmp/restore.agz"
echo "    sudo docker exec ${CONTAINER} mongorestore --uri=\"mongodb://${MONGO_USER}:${MONGO_PASS}@localhost:27017/?authSource=admin\" --db=${DB_NAME} --drop --gzip --archive=/tmp/restore.agz"
