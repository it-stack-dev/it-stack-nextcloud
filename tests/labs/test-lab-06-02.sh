#!/usr/bin/env bash
# test-lab-06-02.sh — Lab 06-02: External Dependencies
# Module 06: Nextcloud file sync, calendar, and office suite
# nextcloud with external PostgreSQL, Redis, and network integration
set -euo pipefail

LAB_ID="06-02"
LAB_NAME="External Dependencies"
MODULE="nextcloud"
COMPOSE_FILE="docker/docker-compose.lan.yml"
PASS=0
FAIL=0

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'

pass() { echo -e "${GREEN}[PASS]${NC} $1"; ((PASS++)); }
fail() { echo -e "${RED}[FAIL]${NC} $1"; ((FAIL++)); }
info() { echo -e "${CYAN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

echo -e "${CYAN}======================================${NC}"
echo -e "${CYAN} Lab ${LAB_ID}: ${LAB_NAME}${NC}"
echo -e "${CYAN} Module: ${MODULE}${NC}"
echo -e "${CYAN}======================================${NC}"
echo ""

# ── PHASE 1: Setup ────────────────────────────────────────────────────────────
info "Phase 1: Setup"
docker compose -f "${COMPOSE_FILE}" up -d
info "Waiting for PostgreSQL..."
timeout 60 bash -c 'until docker compose -f docker/docker-compose.lan.yml exec -T db pg_isready -U ncuser -d nextcloud 2>/dev/null; do sleep 3; done'
info "Waiting for Redis..."
timeout 30 bash -c 'until docker compose -f docker/docker-compose.lan.yml exec -T redis redis-cli -a Lab02Redis! ping 2>/dev/null | grep -q PONG; do sleep 2; done'
info "Waiting for Nextcloud (PostgreSQL first-boot ~3 min)..."
timeout 360 bash -c 'until curl -sf http://localhost:8080/status.php | grep -q "\"installed\":true"; do sleep 10; done'

# ── PHASE 2: Health Checks ───────────────────────────────────────────────────
info "Phase 2: Health Checks"

for c in nc-lan-db nc-lan-redis nc-lan-app; do
  if docker ps --filter "name=^/${c}$" --filter "status=running" --format '{{.Names}}' | grep -q "${c}"; then
    pass "Container ${c} is running"
  else
    fail "Container ${c} is not running"
  fi
done

if docker compose -f "${COMPOSE_FILE}" exec -T db pg_isready -U ncuser -d nextcloud 2>/dev/null; then
  pass "PostgreSQL: pg_isready OK"
else
  fail "PostgreSQL: pg_isready failed"
fi

if docker compose -f "${COMPOSE_FILE}" exec -T redis redis-cli -a Lab02Redis! ping 2>/dev/null | grep -q PONG; then
  pass "Redis: PING → PONG"
else
  fail "Redis: no PONG response"
fi

if curl -sf http://localhost:8080/status.php | grep -q '"installed":true'; then
  pass "Nextcloud: status.php installed=true"
else
  fail "Nextcloud: status.php not installed"
fi

# ── PHASE 3: Functional Tests ────────────────────────────────────────────────
info "Phase 3: Functional Tests (Lab 02 — External Dependencies)"

# Key Lab 02 test: database backend must be PostgreSQL, not SQLite
DB_TYPE=$(docker compose -f "${COMPOSE_FILE}" exec -T nextcloud \
  php /var/www/html/occ config:system:get dbtype 2>/dev/null | tr -d '[:space:]' || echo "unknown")
if echo "${DB_TYPE}" | grep -qiE '^pgsql|^postgresql'; then
  pass "DB backend: ${DB_TYPE} (PostgreSQL confirmed, not SQLite)"
else
  fail "DB backend: expected pgsql, got '${DB_TYPE}'"
fi

# Key Lab 02 test: Redis must be configured in config.php
if docker compose -f "${COMPOSE_FILE}" exec -T nextcloud \
    cat /var/www/html/config/config.php 2>/dev/null | grep -q "'redis'"; then
  pass "Redis section present in Nextcloud config.php"
else
  fail "Redis not configured in config.php"
fi

# DB host is 'db' (external, not localhost)
DB_HOST=$(docker compose -f "${COMPOSE_FILE}" exec -T nextcloud \
  php /var/www/html/occ config:system:get dbhost 2>/dev/null | tr -d '[:space:]' || echo "")
if [ "${DB_HOST}" = "db" ]; then
  pass "DB host: '${DB_HOST}' (external service)"
else
  fail "DB host: expected 'db', got '${DB_HOST}'"
fi

# Maintenance mode off
MAINTENANCE=$(docker compose -f "${COMPOSE_FILE}" exec -T nextcloud \
  php /var/www/html/occ config:system:get maintenance 2>/dev/null | tr -d '[:space:]' || echo "false")
if [ "${MAINTENANCE}" = "false" ]; then
  pass "Maintenance mode: disabled"
else
  fail "Maintenance mode: enabled (unexpected)"
fi

# occ status
if docker compose -f "${COMPOSE_FILE}" exec -T nextcloud \
    php /var/www/html/occ status 2>/dev/null | grep -qi 'installed.*true'; then
  pass "occ status: installed=true"
else
  fail "occ status: not installed"
fi

# Admin user in DB
if docker compose -f "${COMPOSE_FILE}" exec -T nextcloud \
    php /var/www/html/occ user:list 2>/dev/null | grep -q admin; then
  pass "occ user:list: admin user present"
else
  fail "occ user:list: admin user missing"
fi

# WebDAV PROPFIND
if curl -sf -u admin:Lab02Password! -X PROPFIND \
    http://localhost:8080/remote.php/dav/ | grep -qi "multistatus"; then
  pass "WebDAV PROPFIND: multistatus response"
else
  fail "WebDAV PROPFIND: no multistatus"
fi

# OCS Capabilities API
if curl -sf -u admin:Lab02Password! \
    'http://localhost:8080/ocs/v1.php/cloud/capabilities?format=json' \
    | grep -q '"status":"ok"'; then
  pass "OCS Capabilities API: status OK"
else
  fail "OCS Capabilities API: unexpected response"
fi

# DB integrity
info "Running occ db:add-missing-indices..."
IDX_OUT=$(docker compose -f "${COMPOSE_FILE}" exec -T nextcloud \
  php /var/www/html/occ db:add-missing-indices --no-interaction 2>&1 || true)
if echo "${IDX_OUT}" | grep -qvi "error"; then
  pass "occ db:add-missing-indices: no errors"
else
  warn "occ db:add-missing-indices: ${IDX_OUT}"
fi

# ── PHASE 4: Cleanup ─────────────────────────────────────────────────────────
info "Phase 4: Cleanup"
docker compose -f "${COMPOSE_FILE}" down -v --remove-orphans
info "Cleanup complete"

# ── Results ──────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}======================================${NC}"
echo -e " Lab ${LAB_ID} Complete"
echo -e " ${GREEN}PASS: ${PASS}${NC} | ${RED}FAIL: ${FAIL}${NC}"
echo -e "${CYAN}======================================${NC}"

if [ "${FAIL}" -gt 0 ]; then
  exit 1
fi
