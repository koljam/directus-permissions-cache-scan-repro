#!/usr/bin/env bash
# End-to-end repro:
#   1. Run setup.sh (creates a test user + policy)
#   2. Time the policy-attach PATCH against an *empty* Redis (baseline)
#   3. Pump N junk keys into Redis
#   4. Time the same PATCH again — observe the slowdown
#
# Usage:  scripts/reproduce.sh [num_keys]
# Default num_keys: 1_000_000
set -euo pipefail

NUM_KEYS=${1:-1000000}
DIRECTUS_URL=${DIRECTUS_URL:-http://localhost:8055}
ADMIN_EMAIL=${ADMIN_EMAIL:-admin@example.com}
ADMIN_PASSWORD=${ADMIN_PASSWORD:-admin}

cd "$(dirname "$0")/.."

bash scripts/setup.sh
. .ids

login() {
  curl -sf -X POST "$DIRECTUS_URL/auth/login" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASSWORD\"}" \
    | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p' | head -n1
}

attach_policy() {
  local token=$1
  curl -sf -X PATCH "$DIRECTUS_URL/users/$USER_ID" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -d "{\"policies\":{\"create\":[{\"user\":\"$USER_ID\",\"policy\":{\"id\":\"$POLICY_ID\"}}],\"update\":[],\"delete\":[]}}" \
    -o /dev/null -w "HTTP %{http_code}  TTFB=%{time_starttransfer}s  total=%{time_total}s\n"
}

clear_policies() {
  local token=$1
  curl -sf -X PATCH "$DIRECTUS_URL/users/$USER_ID" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -d '{"policies":[]}' -o /dev/null -w "  (cleared in %{time_total}s)\n"
}

echo
echo "================================================================"
echo "  Step 1: baseline — Redis is empty"
echo "================================================================"
docker compose exec -T redis redis-cli -a redispw --no-auth-warning FLUSHDB >/dev/null
TOKEN=$(login); clear_policies "$TOKEN" >/dev/null
TOKEN=$(login)
echo -n "  PATCH /users/$USER_ID (attach policy):  "
attach_policy "$TOKEN"

echo
echo "================================================================"
echo "  Step 2: pump $NUM_KEYS junk keys into Redis"
echo "================================================================"
bash scripts/pump-redis.sh "$NUM_KEYS"

echo
echo "================================================================"
echo "  Step 3: same PATCH, now against the populated Redis"
echo "================================================================"
TOKEN=$(login); clear_policies "$TOKEN"
TOKEN=$(login)
echo -n "  PATCH /users/$USER_ID (attach policy):  "
attach_policy "$TOKEN"

echo
echo "Compare the TTFB values above."
echo "On default settings (CACHE_ENABLED=false, CACHE_STORE=memory, REDIS_HOST set),"
echo "Step 3 takes orders of magnitude longer than Step 1."
echo
echo "To verify the workaround, restart the stack with the override:"
echo "  docker compose down"
echo "  docker compose -f docker-compose.yml -f docker-compose.fix.yml up -d"
echo "  scripts/reproduce.sh $NUM_KEYS"
echo "Step 3 should now match Step 1 again."
