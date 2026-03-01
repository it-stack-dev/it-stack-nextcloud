#!/usr/bin/env bash
# test-lab-06-01.sh -- Nextcloud Lab 01: Standalone
# Tests: HTTP health, status.php, occ status, user list, WebDAV, version
# Usage: bash test-lab-06-01.sh
set -euo pipefail

PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; ((PASS++)); }
fail(){ echo "[FAIL] $1"; ((FAIL++)); }
info(){ echo "[INFO] $1"; }

# -- Section 1: Container running --------------------------------------------
info "Section 1: Container health"
container_status=$(docker inspect --format '{{.State.Status}}' it-stack-nextcloud-standalone 2>/dev/null || echo "not-found")
info "Container status: $container_status"
[[ "$container_status" == "running" ]] && ok "Container running" || fail "Container running (got: $container_status)"

# -- Section 2: HTTP endpoint -------------------------------------------------
info "Section 2: HTTP :8080 responds"
http_code=$(curl -so /dev/null -w "%{http_code}" http://localhost:8080/ 2>/dev/null || echo "000")
info "GET http://localhost:8080/ -> $http_code"
if [[ "$http_code" =~ ^(200|301|302)$ ]]; then ok "HTTP :8080 responds ($http_code)"; else fail "HTTP :8080 (got $http_code)"; fi

# -- Section 3: status.php ----------------------------------------------------
info "Section 3: /status.php reports installed"
status_json=$(curl -sf http://localhost:8080/status.php 2>/dev/null || echo '{}')
info "status.php: $status_json"
if echo "$status_json" | grep -q '"installed":true'; then
  ok "Nextcloud installed (status.php)"
else
  fail "Nextcloud not installed yet (status.php: $status_json)"
fi

# -- Section 4: Extract version -----------------------------------------------
info "Section 4: Nextcloud version"
version=$(echo "$status_json" | grep -o '"version":"[^"]*"' | cut -d'"' -f4 || echo "unknown")
info "Version: $version"
[[ -n "$version" && "$version" != "unknown" ]] && ok "Nextcloud version: $version" || fail "Nextcloud version not readable"

# -- Section 5: Maintenance mode OFF ------------------------------------------
info "Section 5: Maintenance mode"
maintenance=$(echo "$status_json" | grep -o '"maintenance":[^,}]*' | cut -d: -f2 | tr -d ' ' || echo "unknown")
info "Maintenance: $maintenance"
[[ "$maintenance" == "false" ]] && ok "Maintenance mode: off" || fail "Maintenance mode (got: $maintenance)"

# -- Section 6: occ status (via docker exec) ----------------------------------
info "Section 6: occ status inside container"
if docker exec it-stack-nextcloud-standalone php occ status 2>/dev/null | grep -q "installed: true"; then
  ok "occ status: installed = true"
else
  fail "occ status: installed not true"
fi

# -- Section 7: occ user:list shows admin ------------------------------------
info "Section 7: Admin user exists (occ user:list)"
if docker exec it-stack-nextcloud-standalone php occ user:list 2>/dev/null | grep -qi "admin"; then
  ok "Admin user present in occ user:list"
else
  fail "Admin user not found in occ user:list"
fi

# -- Section 8: WebDAV endpoint accessible ------------------------------------
info "Section 8: WebDAV endpoint"
webdav_code=$(curl -sf -X PROPFIND http://localhost:8080/remote.php/dav/ \
  -H "Depth: 0" -u admin:Lab01Password! -o /dev/null -w "%{http_code}" 2>/dev/null || echo "000")
info "WebDAV PROPFIND -> $webdav_code"
if [[ "$webdav_code" =~ ^(207|401)$ ]]; then ok "WebDAV :8080 endpoint present ($webdav_code)"; else fail "WebDAV endpoint (got $webdav_code)"; fi

# -- Section 9: OCS capabilities API -----------------------------------------
info "Section 9: OCS Capabilities API"
ocs_code=$(curl -sf -u admin:Lab01Password! \
  "http://localhost:8080/ocs/v2.php/cloud/capabilities?format=json" \
  -o /dev/null -w "%{http_code}" 2>/dev/null || echo "000")
info "OCS capabilities -> $ocs_code"
[[ "$ocs_code" == "200" ]] && ok "OCS Capabilities API: 200" || fail "OCS Capabilities API (got $ocs_code)"

# -- Section 10: Files app enabled --------------------------------------------
info "Section 10: Files app enabled"
if docker exec it-stack-nextcloud-standalone php occ app:list --enabled 2>/dev/null | grep -q "files:"; then
  ok "Files app enabled"
else
  fail "Files app not enabled"
fi

# -- Section 11: Integration score -------------------------------------------
info "Section 11: Lab 01 standalone integration score"
TOTAL=$((PASS + FAIL))
echo "Results: $PASS/$TOTAL passed"
if [[ $FAIL -eq 0 ]]; then
  echo "[SCORE] 6/6 -- All standalone checks passed"
  exit 0
else
  echo "[SCORE] FAIL ($FAIL failures)"
  exit 1
fi
