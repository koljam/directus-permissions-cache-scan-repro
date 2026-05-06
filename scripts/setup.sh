#!/usr/bin/env bash
# Wait for Directus, log in, create a test user and a test policy.
# Writes IDs to .ids (sourced by reproduce.sh).
set -euo pipefail

DIRECTUS_URL=${DIRECTUS_URL:-http://localhost:8055}
ADMIN_EMAIL=${ADMIN_EMAIL:-admin@example.com}
ADMIN_PASSWORD=${ADMIN_PASSWORD:-admin}

echo "[setup] waiting for Directus at $DIRECTUS_URL ..."
for _ in $(seq 1 90); do
  if curl -sf "$DIRECTUS_URL/server/health" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
curl -sf "$DIRECTUS_URL/server/health" >/dev/null || { echo "[setup] Directus did not become healthy"; exit 1; }
echo "[setup] Directus is up."

echo "[setup] logging in ..."
TOKEN=$(curl -sf -X POST "$DIRECTUS_URL/auth/login" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASSWORD\"}" | jq -r .data.access_token)
[ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] || { echo "[setup] login failed"; exit 1; }

echo "[setup] creating test user ..."
USER_ID=$(curl -sf -X POST "$DIRECTUS_URL/users" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"email":"victim@example.com","password":"victim","first_name":"Victim"}' | jq -r .data.id)
echo "[setup] USER_ID=$USER_ID"

echo "[setup] creating test policy ..."
POLICY_ID=$(curl -sf -X POST "$DIRECTUS_URL/policies" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"Repro Policy","app_access":true,"icon":"badge"}' | jq -r .data.id)
echo "[setup] POLICY_ID=$POLICY_ID"

cat > "$(dirname "$0")/../.ids" <<EOF
USER_ID=$USER_ID
POLICY_ID=$POLICY_ID
EOF
echo "[setup] wrote .ids"
