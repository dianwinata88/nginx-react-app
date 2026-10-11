#!/bin/sh
# Runs before nginx starts (docker-entrypoint.d). Bakes the node identity
# into a JS file the React app reads, so the UI shows which node served it.
set -eu
echo "window.__NODE_ID__=\"${NODE_ID:-unknown}\";" > /usr/share/nginx/html/config.js
