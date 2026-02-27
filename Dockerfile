# Dockerfile — IT-Stack NEXTCLOUD wrapper
# Module 06 | Category: collaboration | Phase: 2
# Base image: nextcloud:28-apache

FROM nextcloud:28-apache

# Labels
LABEL org.opencontainers.image.title="it-stack-nextcloud" \
      org.opencontainers.image.description="Nextcloud file sync, calendar, and office suite" \
      org.opencontainers.image.vendor="it-stack-dev" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.source="https://github.com/it-stack-dev/it-stack-nextcloud"

# Copy custom configuration and scripts
COPY src/ /opt/it-stack/nextcloud/
COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -f http://localhost/health || exit 1

ENTRYPOINT ["/entrypoint.sh"]
