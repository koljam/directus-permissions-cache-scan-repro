#!/usr/bin/env bash
# Pump N junk keys into Redis to mimic a shared instance (e.g. with BullMQ).
# Defaults to 1_000_000. Pass a different count as the first arg.
set -euo pipefail

COUNT=${1:-1000000}
BATCH_SIZE=10000
REDIS_SERVICE=${REDIS_SERVICE:-redis}
REDIS_PASSWORD=${REDIS_PASSWORD:-redispw}

CLI="docker compose exec -T $REDIS_SERVICE redis-cli -a $REDIS_PASSWORD --no-auth-warning"

echo "[pump] flushing redis ..."
$CLI FLUSHDB >/dev/null

echo "[pump] inserting $COUNT junk keys (bull:queue:*) ..."
batches=$((COUNT / BATCH_SIZE))
START=$(date +%s)
for batch in $(seq 0 $((batches - 1))); do
  $CLI EVAL "for i=1,$BATCH_SIZE do redis.call('SET', 'bull:queue:'..(($batch*$BATCH_SIZE)+i), 'x') end return 1" 0 >/dev/null
done
END=$(date +%s)
DBSIZE=$($CLI DBSIZE | tr -d '\r')
echo "[pump] done in $((END - START))s. DBSIZE=$DBSIZE"
