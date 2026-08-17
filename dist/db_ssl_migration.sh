#!/usr/bin/env bash
# db_ssl_migration.sh
# Self-contained: no separate .js file needed. Pipes the migration script
# into mongosh inside the running mongodb container.
#
# Usage:
#   sudo bash db_ssl_migration.sh            # dry run (default, nothing written)
#   sudo bash db_ssl_migration.sh --apply    # actually rewrites the fields
#
# Always run backup_traffic_data.sh first. Stop gateway + ws-publisher before
# running with --apply.

set -euo pipefail

CONTAINER="mongodb"
MONGO_USER="admin"
MONGO_PASS="admin6754"
DB_NAME="traffic_data"

DRY_RUN="true"
if [[ "${1:-}" == "--apply" ]]; then
  DRY_RUN="false"
fi

echo "==> Checking container '${CONTAINER}' is running"
if ! sudo docker ps --format '{{.Names}}' | grep -qx "${CONTAINER}"; then
  echo "ERROR: container '${CONTAINER}' is not running. Aborting." >&2
  exit 1
fi

if [[ "${DRY_RUN}" == "false" ]]; then
  echo "==> MODE: APPLY -- this will write to ${DB_NAME}"
  read -r -p "    Have you run backup_traffic_data.sh and stopped gateway/ws-publisher? [y/N] " CONFIRM
  if [[ "${CONFIRM}" != "y" && "${CONFIRM}" != "Y" ]]; then
    echo "Aborted, nothing was touched."
    exit 1
  fi
else
  echo "==> MODE: DRY RUN -- nothing will be written"
fi

sudo docker exec -i "${CONTAINER}" mongosh \
  "mongodb://${MONGO_USER}:${MONGO_PASS}@localhost:27017/${DB_NAME}?authSource=admin" \
  --quiet <<EOF
(function () {
  const DRY_RUN = ${DRY_RUN};

  const MARK = "/hazen-tms/";
  // NOTE: live collection names on this box are underscored (alpr_data,
  // violation_data), not the canonical alprdata/violationdata from the
  // documented schema. This is the known gateway naming-mismatch bug
  // (project_context.md open issue). Do not "fix" these back to the
  // canonical names here -- that's a separate change with its own blast
  // radius (API queries, Change Stream watchers). Point at what actually
  // holds data on this box.
  const COLLECTIONS = ["alpr_data", "violation_data"];
  const BATCH = 500;

  // Walks a document and collects [path, newValue] pairs for strings that
  // need rewriting. Recurses into subdocuments and arrays. _id is skipped.
  function collectRewrites(node, path, acc, orphans) {
    if (node === null || node === undefined) return;

    if (typeof node === "string") {
      if (node === "") return;
      const i = node.indexOf(MARK);
      if (i > 0) {
        acc.push({ path: path, value: node.substring(i) });
      } else if (i < 0 && /:9000|hazen-tms/i.test(node)) {
        orphans.push({ path: path, value: node });
      }
      return;
    }

    if (Array.isArray(node)) {
      for (let k = 0; k < node.length; k++) {
        collectRewrites(node[k], path ? path + "." + k : String(k), acc, orphans);
      }
      return;
    }

    if (typeof node === "object") {
      for (const key of Object.keys(node)) {
        if (key === "_id") continue;
        collectRewrites(node[key], path ? path + "." + key : key, acc, orphans);
      }
    }
  }

  const report = [];

  for (const collName of COLLECTIONS) {
    const coll = db.getCollection(collName);
    const total = coll.countDocuments({});
    const pathHits = {};
    const orphans = [];
    let scanned = 0, touchedDocs = 0, touchedFields = 0, written = 0;
    let ops = [];

    function flush() {
      if (ops.length === 0) return;
      if (!DRY_RUN) {
        const res = coll.bulkWrite(ops, { ordered: false });
        written += res.modifiedCount;
      }
      ops = [];
    }

    const cursor = coll.find({}).batchSize(BATCH);
    while (cursor.hasNext()) {
      const doc = cursor.next();
      scanned++;

      const acc = [];
      collectRewrites(doc, "", acc, orphans);

      if (acc.length > 0) {
        touchedDocs++;
        touchedFields += acc.length;
        const setStage = {};
        acc.forEach(function (r) {
          setStage[r.path] = r.value;
          pathHits[r.path] = (pathHits[r.path] || 0) + 1;
        });
        ops.push({ updateOne: { filter: { _id: doc._id }, update: { \$set: setStage } } });
        if (ops.length >= BATCH) flush();
      }

      if (scanned % 5000 === 0) print(collName + ": scanned " + scanned + " / " + total);
    }
    flush();

    report.push({
      collection: collName,
      totalDocs: total,
      docsNeedingFix: touchedDocs,
      fieldsRewritten: touchedFields,
      actuallyWritten: DRY_RUN ? "(dry run)" : written,
      fieldPaths: pathHits,
      unanchored: orphans.length ? orphans.slice(0, 10) : "none"
    });
  }

  printjson({ mode: DRY_RUN ? "DRY RUN, nothing written" : "APPLIED", results: report });
})();
EOF

echo "==> Done."
if [[ "${DRY_RUN}" == "true" ]]; then
  echo "==> This was a dry run. Review 'unanchored' (should be 'none') and 'fieldPaths' above."
  echo "==> Re-run with --apply once satisfied: sudo bash db_ssl_migration.sh --apply"
fi
