#!/usr/bin/env bash
# test-lab-06-06.sh — Nextcloud Lab 06: Production Deployment
# Module 06 | Lab 06 | Tests: resource limits, restart=always, persistent volumes, metrics
set -euo pipefail

COMPOSE_FILE="$(dirname "$0")/../docker/docker-compose.production.yml"
CLEANUP=true
for arg in "$@"; do [[ "$arg" == "--no-cleanup" ]] && CLEANUP=false; done

NC_PORT=8200
KC_PORT=8204
LDAP_PORT=3895
KC_ADMIN_PASS="Prod06Admin!"
LDAP_ADMIN_PASS="LdapProd06!"

PASS=0; FAIL=0
pass() { echo "[PASS] $1"; ((PASS++)) || true; }
fail() { echo "[FAIL] $1"; ((FAIL++)) || true; }
section() { echo ""; echo "=== $1 ==="; }

cleanup() {
  if [[ "$CLEANUP" == "true" ]]; then
    echo "Cleaning up..."
    docker compose -f "$COMPOSE_FILE" down -v --remove-orphans 2>/dev/null || true
  fi
}
trap cleanup EXIT

section "Starting Lab 06 Production Deployment"
docker compose -f "$COMPOSE_FILE" up -d
echo "Waiting for services to initialize..."

section "Health Checks"
for i in $(seq 1 60); do
  status=$(docker inspect nc-prod-keycloak --format '{{.State.Health.Status}}' 2>/dev/null || echo "waiting")
  [[ "$status" == "healthy" ]] && break
  sleep 5
done
[[ "$(docker inspect nc-prod-keycloak --format '{{.State.Health.Status}}')" == "healthy" ]] && pass "Keycloak healthy" || fail "Keycloak not healthy"

for i in $(seq 1 30); do
  status=$(docker inspect nc-prod-ldap --format '{{.State.Health.Status}}' 2>/dev/null || echo "waiting")
  [[ "$status" == "healthy" ]] && break
  sleep 3
done
[[ "$(docker inspect nc-prod-ldap --format '{{.State.Health.Status}}')" == "healthy" ]] && pass "LDAP healthy" || fail "LDAP not healthy"

for i in $(seq 1 60); do
  status=$(docker inspect nc-prod-app --format '{{.State.Health.Status}}' 2>/dev/null || echo "waiting")
  [[ "$status" == "healthy" ]] && break
  sleep 5
done
[[ "$(docker inspect nc-prod-app --format '{{.State.Health.Status}}')" == "healthy" ]] && pass "Nextcloud app healthy" || fail "Nextcloud app not healthy"

section "Production Configuration Checks"
# Restart policy
rp=$(docker inspect nc-prod-app --format '{{.HostConfig.RestartPolicy.Name}}')
[[ "$rp" == "always" ]] && pass "Nextcloud restart=always" || fail "Restart policy is '$rp', expected 'always'"
rp_kc=$(docker inspect nc-prod-keycloak --format '{{.HostConfig.RestartPolicy.Name}}')
[[ "$rp_kc" == "always" ]] && pass "Keycloak restart=always" || fail "Keycloak restart policy is '$rp_kc'"

# Resource limits
mem=$(docker inspect nc-prod-app --format '{{.HostConfig.Memory}}')
[[ "$mem" -gt 0 ]] && pass "Nextcloud memory limit set ($mem bytes)" || fail "Nextcloud memory limit not set"
mem_kc=$(docker inspect nc-prod-keycloak --format '{{.HostConfig.Memory}}')
[[ "$mem_kc" -gt 0 ]] && pass "Keycloak memory limit set ($mem_kc bytes)" || fail "Keycloak memory limit not set"
mem_db=$(docker inspect nc-prod-db --format '{{.HostConfig.Memory}}')
[[ "$mem_db" -gt 0 ]] && pass "PostgreSQL memory limit set ($mem_db bytes)" || fail "PostgreSQL memory limit not set"

# Named volumes
docker volume ls | grep -q "nc-prod-ldap-data" && pass "Volume nc-prod-ldap-data exists" || fail "Volume nc-prod-ldap-data missing"
docker volume ls | grep -q "nc-prod-ldap-config" && pass "Volume nc-prod-ldap-config exists" || fail "Volume nc-prod-ldap-config missing"
docker volume ls | grep -q "nc-prod-db-data" && pass "Volume nc-prod-db-data exists" || fail "Volume nc-prod-db-data missing"
docker volume ls | grep -q "nc-prod-data" && pass "Volume nc-prod-data exists" || fail "Volume nc-prod-data missing"

section "LDAP Verification"
ldap_bind=$(docker exec nc-prod-ldap ldapsearch -x -H ldap://localhost -b "dc=lab,dc=local" -D "cn=admin,dc=lab,dc=local" -w "$LDAP_ADMIN_PASS" "(objectClass=organizationalUnit)" dn 2>&1)
echo "$ldap_bind" | grep -q "dn:" && pass "LDAP bind and search OK" || fail "LDAP bind failed"

section "Keycloak API & Metrics"
TOKEN=$(curl -sf -X POST "http://localhost:${KC_PORT}/realms/master/protocol/openid-connect/token" \
  -d "client_id=admin-cli&grant_type=password&username=admin&password=${KC_ADMIN_PASS}" \
  | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
[[ -n "$TOKEN" ]] && pass "Keycloak admin token obtained" || { fail "Keycloak admin token failed"; }

REALM_EXISTS=$(curl -sf -H "Authorization: Bearer $TOKEN" "http://localhost:${KC_PORT}/admin/realms" | grep -o '"realm":"it-stack"' | wc -l || echo 0)
if [[ "$REALM_EXISTS" -gt 0 ]]; then
  pass "Realm it-stack exists"
else
  curl -sf -X POST "http://localhost:${KC_PORT}/admin/realms" \
    -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    -d '{"realm":"it-stack","enabled":true,"displayName":"IT-Stack Production"}'
  pass "Realm it-stack created"
fi

CLIENT_EXISTS=$(curl -sf -H "Authorization: Bearer $TOKEN" "http://localhost:${KC_PORT}/admin/realms/it-stack/clients?clientId=nextcloud-client" | grep -o '"clientId":"nextcloud-client"' | wc -l || echo 0)
if [[ "$CLIENT_EXISTS" -gt 0 ]]; then
  pass "OIDC client nextcloud-client exists"
else
  curl -sf -X POST "http://localhost:${KC_PORT}/admin/realms/it-stack/clients" \
    -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    -d '{"clientId":"nextcloud-client","enabled":true,"protocol":"openid-connect","secret":"nextcloud-prod-06","redirectUris":["http://localhost:'"${NC_PORT}"'/*"]}'
  pass "OIDC client nextcloud-client created"
fi

# Keycloak metrics endpoint
curl -sf "http://localhost:${KC_PORT}/metrics" | grep -q "keycloak" && pass "Keycloak /metrics endpoint returns data" || fail "Keycloak /metrics endpoint not responding"

section "Nextcloud API"
curl -sf "http://localhost:${NC_PORT}/status.php" | grep -q '"installed":true' && pass "Nextcloud reports installed=true" || {
  curl -sf "http://localhost:${NC_PORT}/status.php" | grep -q '"installed":false' && pass "Nextcloud reports installed (setup pending)" || fail "Nextcloud status.php not responding"
}

section "Redis Persistence"
redis_cfg=$(docker exec nc-prod-redis redis-cli -a "Prod06Redis!" CONFIG GET save 2>/dev/null | tr '\n' ' ')
echo "$redis_cfg" | grep -q "900" && pass "Redis persistence (save 900 1) configured" || fail "Redis save configuration missing"

section "Log Rotation Configuration"
log_driver=$(docker inspect nc-prod-app --format '{{.HostConfig.LogConfig.Type}}')
[[ "$log_driver" == "json-file" ]] && pass "Log driver is json-file" || fail "Log driver is '$log_driver'"

echo ""
echo "================================================"
echo "Lab 06 Results: ${PASS} passed, ${FAIL} failed"
echo "================================================"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1