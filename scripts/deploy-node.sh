#!/usr/bin/env bash
# Runs on ONE app-node host (invoked over SSH by CI).
# Expects env: NODE_ID (e.g. node-a), IMAGE_TAG, GHCR_TOKEN (for private images).
set -euo pipefail

APP_DIR=/opt/nginx-react-app
cd "$APP_DIR"

echo "${GHCR_TOKEN}" | docker login ghcr.io -u token --password-stdin 2>/dev/null || true

export IMAGE_TAG="${IMAGE_TAG:-latest}"
export NODE_ID

docker compose -f docker-compose.node.yml pull app
docker compose -f docker-compose.node.yml up -d app

# Wait for the node to answer before letting the pipeline move on.
for i in $(seq 1 30); do
  if curl -fs http://localhost/healthz >/dev/null 2>&1; then
    echo "node ${NODE_ID} healthy"
    exit 0
  fi
  sleep 2
done
echo "node ${NODE_ID} failed to become healthy" >&2
exit 1
