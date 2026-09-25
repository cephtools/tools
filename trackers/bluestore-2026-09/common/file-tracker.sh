#!/bin/bash
# File one record on tracker.ceph.com through the Redmine REST API.
#
#   REDMINE_API_KEY=<key> bash file-tracker.sh <record-dir> [--post]
#
# Without --post it only shows what would be sent (dry run).
# The API key is on https://tracker.ceph.com/my/account ("API access key").
# The new issue number is written to <record-dir>/TRACKER so a record is never
# filed twice.
set -eu
d=${1:?record dir}; post=${2:-}
here=$(cd "$(dirname "$0")" && pwd)
[ -f "$d/TRACKER" ] && { echo "already filed: $(cat "$d/TRACKER")"; exit 1; }
python3 "$here/to-tracker.py" "$d" >/dev/null
json="$d/tracker.json"
python3 -c 'import json,sys; i=json.load(open(sys.argv[1]))["issue"]; print("Project :", i["project_id"]); print("Subject :", i["subject"]); print("Fields  :", i["custom_fields"]); print("Body    :", len(i["description"]), "chars")' "$json"
if [ "$post" != "--post" ]; then
  echo "(dry run; review $d/tracker.textile, then re-run with --post)"
  exit 0
fi
: "${REDMINE_API_KEY:?set REDMINE_API_KEY}"
resp=$(curl -sS -X POST -H "Content-Type: application/json" \
  -H "X-Redmine-API-Key: $REDMINE_API_KEY" \
  --data @"$json" https://tracker.ceph.com/issues.json)
id=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["issue"]["id"])' "$resp" 2>/dev/null) || {
  echo "filing failed: $resp"; exit 1; }
echo "https://tracker.ceph.com/issues/$id" | tee "$d/TRACKER"
