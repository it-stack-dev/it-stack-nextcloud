#!/usr/bin/env bash
# test-lab-06-03.sh — Lab 06-03: Nextcloud Advanced Features
# Tests: cron worker, resource limits, Redis memory policy, PHP tuning
set -euo pipefail
COMPOSE_FILE="docker/docker-compose.advanced.yml"
PASS=0; FAIL=0
pass() { echo "  [PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }
section() { echo; echo "=== $1 ==="; }

section "Container health"
for c in nc-adv-db nc-adv-redis nc-adv-app nc-adv-cron; do
  if docker inspect --format '{{.State.Running}}' "$c" 2>/dev/null | grep -q true; then
    pass "Container $c is running"
  else
    fail "Container $c is not running"
  fi
done

section "PostgreSQL connectivity"
if docker compose -f "$COMPOSE_FILE" exec -T db pg_isready -U ncuser -d nextcloud 2>/dev/null | grep -q "accepting"; then
  pass "PostgreSQL accepting connections"
else
  fail "PostgreSQL not ready"
fi

section "Redis connectivity and memory policy"
REDIS_PONG=$(docker compose -f "$COMPOSE_FILE" exec -T redis redis-cli -a Lab03Redis! PING 2>/dev/null | tr -d '[:space:]') || REDIS_PONG=""
if [ "$REDIS_PONG" = "PONG" ]; then
  pass "Redis PING responded"
else
  fail "Redis PING failed"
fi
REDIS_POLICY=$(docker compose -f "$COMPOSE_FILE" exec -T redis redis-cli -a Lab03Redis! CONFIG GET maxmemory-policy 2>/dev/null | tail -1 | tr -d '[:space:]') || REDIS_POLICY=""
if [ "$REDIS_POLICY" = "allkeys-lru" ]; then
  pass "Redis maxmemory-policy = allkeys-lru"
else
  fail "Redis maxmemory-policy unexpected: '$REDIS_POLICY'"
fi

section "Nextcloud HTTP health"
HTTP_CODE=$(curl -sw '%{http_code}' -o /dev/null http://localhost:8080/status.php 2>/dev/null) || HTTP_CODE="000"
if [ "$HTTP_CODE" = "200" ]; then
  pass "Nextcloud /status.php HTTP 200"
else
  fail "Nextcloud /status.php returned $HTTP_CODE"
fi
STATUS=$(curl -sf http://localhost:8080/status.php 2>/dev/null) || STATUS=""
if echo "$STATUS" | grep -q '"installed":true'; then
  pass "Nextcloud reports installed=true"
else
  fail "Nextcloud not reporting installed"
fi

section "PHP memory limit in container env"
NC_ENV=$(docker inspect nc-adv-app --format '{{json .Config.Env}}' 2>/dev/null) || NC_ENV="[]"
if echo "$NC_ENV" | grep -q "PHP_MEMORY_LIMIT=512M"; then
  pass "PHP_MEMORY_LIMIT=512M set in container"
else
  fail "PHP_MEMORY_LIMIT=512M not found in container env"
fi
if echo "$NC_ENV" | grep -q "PHP_UPLOAD_LIMIT=512M"; then
  pass "PHP_UPLOAD_LIMIT=512M set in container"
else
  fail "PHP_UPLOAD_LIMIT=512M not found in container env"
fi

section "Resource limits check"
NC_MEM=$(docker inspect nc-adv-app --format '{{.HostConfig.Memory}}' 2>/dev/null) || NC_MEM="0"
if [ "$NC_MEM" = "1073741824" ]; then
  pass "nc-adv-app memory limit = 1G (1073741824 bytes)"
else
  fail "nc-adv-app memory limit: expected 1073741824, got $NC_MEM"
fi

section "Cron worker container"
CRON_STATUS=$(docker inspect nc-adv-cron --format '{{.State.Running}}' 2>/dev/null) || CRON_STATUS="false"
if [ "$CRON_STATUS" = "true" ]; then
  pass "nc-adv-cron is running"
else
  fail "nc-adv-cron is not running"
fi

section "Trusted proxies configuration"
TRUSTED=$(docker compose -f "$COMPOSE_FILE" exec -T app php occ config:system:get trusted_proxies 0 2>/dev/null) || TRUSTED=""
if echo "$TRUSTED" | grep -qE "172\.16|10\.0"; then
  pass "Trusted proxies configured"
else
  fail "Trusted proxies not set (occ output: '$TRUSTED')"
fi

section "Background jobs mode"
BG_MODE=$(docker compose -f "$COMPOSE_FILE" exec -T app php occ config:system:get backgroundjobs_mode 2>/dev/null | tr -d '[:space:]') || BG_MODE=""
if [ "$BG_MODE" = "cron" ]; then
  pass "backgroundjobs_mode = cron"
else
  fail "backgroundjobs_mode: expected 'cron', got '$BG_MODE'"
fi

section "WebDAV endpoint"
WEBDAV=$(curl -sw '%{http_code}' -o /dev/null -u admin:Lab03Admin! -X PROPFIND "http://localhost:8080/remote.php/dav/files/admin/" 2>/dev/null) || WEBDAV="000"
if [ "$WEBDAV" = "207" ]; then
  pass "WebDAV PROPFIND HTTP 207"
else
  fail "WebDAV PROPFIND returned $WEBDAV"
fi

echo
echo "====================================="
echo "  Nextcloud Lab 06-03 Results"
echo "  PASS: $PASS  FAIL: $FAIL"
echo "====================================="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1