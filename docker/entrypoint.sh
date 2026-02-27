#!/bin/bash
# entrypoint.sh — IT-Stack nextcloud container entrypoint
set -euo pipefail

echo "Starting IT-Stack NEXTCLOUD (Module 06)..."

# Source any environment overrides
if [ -f /opt/it-stack/nextcloud/config.env ]; then
    # shellcheck source=/dev/null
    source /opt/it-stack/nextcloud/config.env
fi

# Execute the upstream entrypoint or command
exec "$$@"
