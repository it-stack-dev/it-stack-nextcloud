#!/usr/bin/env bash
# test-lab-06-04.sh — Lab 06-04: Nextcloud SSO Integration
# Tests: Keycloak running, OIDC env vars set, Nextcloud accessible, user_oidc config
set -euo pipefail
COMPOSE_FILE="docker/docker-compose.sso.yml"
KC_PORT="8084"
PASS=0; FAIL=0
pass() { echo "  [PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }
section() { echo; echo "=== $1 ==="; }

section "Container health"
for c in nc-sso-db nc-sso-redis nc-sso-keycloak nc-sso-app nc-sso-cron; do
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

section "Keycloak health"
KC_HEALTH=$(curl -sf "http://localhost:${KC_PORT}/health/ready" 2>/dev/null) || KC_HEALTH=""
if echo "$KC_HEALTH" | grep -q "UP"; then
  pass "Keycloak health/ready = UP"
else
  fail "Keycloak health/ready not UP: '$KC_HEALTH'"
fi

section "Keycloak admin API"
KC_TOKEN=$(curl -sf -X POST \
  "http://localhost:${KC_PORT}/realms/master/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "client_id=admin-cli&username=admin&password=Lab04Admin!&grant_type=password" 2>/dev/null \
  | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4) || KC_TOKEN=""
if [ -n "$KC_TOKEN" ]; then
  pass "Keycloak admin token obtained"
else
  fail "Keycloak admin login failed"
fi

section "Keycloak realm creation"
if [ -n "$KC_TOKEN" ]; then
  REALM_RESP=$(curl -sf -X POST \
    "http://localhost:${KC_PORT}/admin/realms" \
    -H "Authorization: Bearer $KC_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"realm":"it-stack","enabled":true,"displayName":"IT-Stack"}' 2>/dev/null; echo $?) || REALM_RESP=1
  REALM_CHECK=$(curl -sf \
    "http://localhost:${KC_PORT}/admin/realms/it-stack" \
    -H "Authorization: Bearer $KC_TOKEN" 2>/dev/null) || REALM_CHECK=""
  if echo "$REALM_CHECK" | grep -q '"realm":"it-stack"'; then
    pass "Keycloak realm 'it-stack' exists"
  else
    fail "Keycloak realm 'it-stack' not found"
  fi
else
  fail "Skipping realm check (no admin token)"
fi

section "Keycloak OIDC client creation"
if [ -n "$KC_TOKEN" ]; then
  curl -sf -X POST \
    "http://localhost:${KC_PORT}/admin/realms/it-stack/clients" \
    -H "Authorization: Bearer $KC_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"clientId":"nextcloud","enabled":true,"publicClient":false,"secret":"nextcloud-secret-04","redirectUris":["http://localhost:8080/*"],"standardFlowEnabled":true,"directAccessGrantsEnabled":true}' \
    2>/dev/null || true
  CLIENTS=$(curl -sf \
    "http://localhost:${KC_PORT}/admin/realms/it-stack/clients?clientId=nextcloud" \
    -H "Authorization: Bearer $KC_TOKEN" 2>/dev/null) || CLIENTS=""
  if echo "$CLIENTS" | grep -q '"clientId":"nextcloud"'; then
    pass "Keycloak OIDC client 'nextcloud' configured"
  else
    fail "Keycloak OIDC client 'nextcloud' not found"
  fi
else
  fail "Skipping client check (no admin token)"
fi

section "Nextcloud OIDC env vars"
NC_ENV=$(docker inspect nc-sso-app --format '{{json .Config.Env}}' 2>/dev/null) || NC_ENV="[]"
if echo "$NC_ENV" | grep -q "NC_oidc_login_provider_url"; then
  pass "NC_oidc_login_provider_url set in container"
else
  fail "NC_oidc_login_provider_url not found in container env"
fi
if echo "$NC_ENV" | grep -q "NC_oidc_login_client_id=nextcloud"; then
  pass "NC_oidc_login_client_id=nextcloud set"
else
  fail "NC_oidc_login_client_id not set to 'nextcloud'"
fi

section "Nextcloud HTTP health"
STATUS=$(curl -sf http://localhost:8080/status.php 2>/dev/null) || STATUS=""
if echo "$STATUS" | grep -q '"installed":true'; then
  pass "Nextcloud reports installed=true"
else
  fail "Nextcloud status.php unexpected: '$STATUS'"
fi

section "Nextcloud login page includes OIDC button env"
if echo "$NC_ENV" | grep -q "NC_oidc_login_button_text=Login with Keycloak"; then
  pass "OIDC button text = 'Login with Keycloak'"
else
  fail "OIDC button text not found in env"
fi

section "Nextcloud OIDC discovery endpoint check"
KC_OIDC=$(curl -sf "http://localhost:${KC_PORT}/realms/it-stack/.well-known/openid-configuration" 2>/dev/null) || KC_OIDC=""
if echo "$KC_OIDC" | grep -q '"issuer"'; then
  pass "Keycloak OIDC discovery endpoint reachable"
else
  fail "Keycloak OIDC discovery endpoint failed"
fi

section "WebDAV admin access"
WEBDAV=$(curl -sw '%{http_code}' -o /dev/null -u admin:Lab04Admin! \
  -X PROPFIND "http://localhost:8080/remote.php/dav/files/admin/" 2>/dev/null) || WEBDAV="000"
if [ "$WEBDAV" = "207" ]; then
  pass "WebDAV PROPFIND HTTP 207 (admin user functional)"
else
  fail "WebDAV PROPFIND returned $WEBDAV"
fi

echo
echo "====================================="
echo "  Nextcloud Lab 06-04 Results"
echo "  PASS: $PASS  FAIL: $FAIL"
echo "====================================="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1