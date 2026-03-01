#!/usr/bin/env bash
# test-lab-06-05.sh -- Lab 05: Nextcloud Advanced Integration
# Tests: OpenLDAP bind, Keycloak realm+client+LDAP-federation, Nextcloud OIDC+LDAP env,
#        Redis session config, cron container, WebDAV
#
# Usage: bash tests/labs/test-lab-06-05.sh [--no-cleanup]
set -euo pipefail

COMPOSE_FILE="docker/docker-compose.integration.yml"
KC_PORT=8104
NC_PORT=8100
LDAP_PORT=3890
KC_ADMIN=admin
KC_PASS="Lab05Admin!"
LDAP_ADMIN_DN="cn=admin,dc=lab,dc=local"
LDAP_PASS="LdapAdmin05!"
READONLY_DN="cn=readonly,dc=lab,dc=local"
READONLY_PASS="ReadOnly05!"
CLEANUP=true
[[ "${1:-}" == "--no-cleanup" ]] && CLEANUP=false

PASS=0; FAIL=0
pass() { echo "[PASS] $1"; ((PASS++)); }
fail() { echo "[FAIL] $1"; ((FAIL++)); }
section() { echo ""; echo "=== $1 ==="; }
cleanup() { $CLEANUP && docker compose -f "$COMPOSE_FILE" down -v 2>/dev/null || true; }
trap cleanup EXIT

section "Lab 06-05: Nextcloud Advanced Integration"
echo "Compose file: $COMPOSE_FILE"

section "1. Start Containers"
docker compose -f "$COMPOSE_FILE" up -d
echo "Waiting for services to initialize..."
sleep 30

section "2. Keycloak Health"
for i in $(seq 1 24); do
  if curl -sf "http://localhost:${KC_PORT}/health/ready" | grep -q "UP"; then
    pass "Keycloak health/ready UP"
    break
  fi
  [[ $i -eq 24 ]] && fail "Keycloak did not become healthy" && exit 1
  sleep 10
done

section "3. OpenLDAP Connectivity"
for i in $(seq 1 12); do
  if docker exec nc-int-ldap ldapsearch -x -H ldap://localhost \
     -b "dc=lab,dc=local" -D "$LDAP_ADMIN_DN" -w "$LDAP_PASS" \
     -s base "(objectClass=*)" >/dev/null 2>&1; then
    pass "LDAP admin bind successful (dc=lab,dc=local)"
    break
  fi
  [[ $i -eq 12 ]] && fail "LDAP bind failed after 120s"
  sleep 10
done

# Verify readonly user
if docker exec nc-int-ldap ldapsearch -x -H ldap://localhost \
   -b "dc=lab,dc=local" -D "$READONLY_DN" -w "$READONLY_PASS" \
   -s base "(objectClass=*)" >/dev/null 2>&1; then
  pass "LDAP readonly bind successful"
else
  fail "LDAP readonly bind failed"
fi

section "4. Keycloak Realm + Client + LDAP Federation"
KC_TOKEN=$(curl -sf "http://localhost:${KC_PORT}/realms/master/protocol/openid-connect/token" \
  -d "client_id=admin-cli&grant_type=password&username=${KC_ADMIN}&password=${KC_PASS}" \
  | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
[[ -n "$KC_TOKEN" ]] && pass "Keycloak admin token obtained" || { fail "Keycloak admin token failed"; exit 1; }

# Create realm
HTTP=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
  "http://localhost:${KC_PORT}/admin/realms" \
  -H "Authorization: Bearer $KC_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"realm":"it-stack","enabled":true,"displayName":"IT-Stack Lab"}')
[[ "$HTTP" =~ ^(201|409)$ ]] && pass "Realm it-stack created (HTTP $HTTP)" || fail "Realm creation failed (HTTP $HTTP)"

# Create OIDC client
CLIENT_PAYLOAD='{"clientId":"nextcloud","name":"Nextcloud","enabled":true,"protocol":"openid-connect","publicClient":false,"redirectUris":["http://localhost:'"${NC_PORT}"'/*"],"secret":"nextcloud-secret-05"}'
HTTP=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
  "http://localhost:${KC_PORT}/admin/realms/it-stack/clients" \
  -H "Authorization: Bearer $KC_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$CLIENT_PAYLOAD")
[[ "$HTTP" =~ ^(201|409)$ ]] && pass "OIDC client nextcloud created (HTTP $HTTP)" || fail "OIDC client creation failed (HTTP $HTTP)"

# Register LDAP user federation
LDAP_FED_PAYLOAD='{"name":"ldap","providerId":"ldap","providerType":"org.keycloak.storage.UserStorageProvider","config":{"vendor":["other"],"connectionUrl":["ldap://nc-int-ldap:389"],"bindDn":["'"$LDAP_ADMIN_DN"'"],"bindCredential":["LdapAdmin05!"],"usersDn":["dc=lab,dc=local"],"usernameLDAPAttribute":["uid"],"rdnLDAPAttribute":["uid"],"uuidLDAPAttribute":["entryUUID"],"userObjectClasses":["inetOrgPerson"],"syncRegistrations":["false"],"enabled":["true"]}}'
HTTP=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
  "http://localhost:${KC_PORT}/admin/realms/it-stack/components" \
  -H "Authorization: Bearer $KC_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$LDAP_FED_PAYLOAD")
[[ "$HTTP" =~ ^(201|409)$ ]] && pass "Keycloak LDAP user federation registered (HTTP $HTTP)" || fail "LDAP federation registration failed (HTTP $HTTP)"

section "5. Nextcloud Health"
for i in $(seq 1 20); do
  if curl -sf "http://localhost:${NC_PORT}/status.php" | grep -q '"installed":true'; then
    pass "Nextcloud status.php installed=true"
    break
  fi
  [[ $i -eq 20 ]] && fail "Nextcloud did not become ready"
  sleep 15
done

section "6. Nextcloud Integration Environment"
NC_ENV=$(docker inspect nc-int-app --format '{{range .Config.Env}}{{.}} {{end}}')

echo "$NC_ENV" | grep -q "NC_oidc_login_provider_url" \
  && pass "NC_oidc_login_provider_url set (Keycloak OIDC)" \
  || fail "NC_oidc_login_provider_url missing"

echo "$NC_ENV" | grep -q "NC_oidc_login_client_id=nextcloud" \
  && pass "NC_oidc_login_client_id=nextcloud" \
  || fail "NC_oidc_login_client_id missing"

echo "$NC_ENV" | grep -q "LDAP_PROVIDER_HOST=nc-int-ldap" \
  && pass "LDAP_PROVIDER_HOST=nc-int-ldap" \
  || fail "LDAP_PROVIDER_HOST missing"

echo "$NC_ENV" | grep -q "LDAP_PROVIDER_BINDDN=cn=readonly" \
  && pass "LDAP_PROVIDER_BINDDN uses readonly account" \
  || fail "LDAP_PROVIDER_BINDDN missing"

echo "$NC_ENV" | grep -q "REDIS_HOST=nc-int-redis" \
  && pass "REDIS_HOST=nc-int-redis" \
  || fail "REDIS_HOST missing"

section "7. Keycloak OIDC Discovery Endpoint"
if curl -sf "http://localhost:${KC_PORT}/realms/it-stack/.well-known/openid-configuration" \
   | grep -q "authorization_endpoint"; then
  pass "Keycloak OIDC discovery endpoint responds"
else
  fail "Keycloak OIDC discovery endpoint unavailable"
fi

# JWKS reachable
if curl -sf "http://localhost:${KC_PORT}/realms/it-stack/protocol/openid-connect/certs" \
   | grep -q "keys"; then
  pass "Keycloak JWKS endpoint (certs) responds"
else
  fail "Keycloak JWKS endpoint unavailable"
fi

section "8. Cron Container Running"
CRON_STATE=$(docker inspect nc-int-cron --format '{{.State.Status}}' 2>/dev/null || echo "missing")
[[ "$CRON_STATE" == "running" ]] \
  && pass "nc-int-cron container running" \
  || fail "nc-int-cron not running (state: $CRON_STATE)"

section "9. WebDAV Endpoint"
HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
  -X PROPFIND "http://localhost:${NC_PORT}/remote.php/dav/")
[[ "$HTTP" == "207" ]] \
  && pass "WebDAV PROPFIND returns 207" \
  || fail "WebDAV PROPFIND returned $HTTP"

section "Summary"
echo "Passed: $PASS | Failed: $FAIL"
[[ $FAIL -eq 0 ]] && echo "Lab 06-05 PASSED" || { echo "Lab 06-05 FAILED"; exit 1; }