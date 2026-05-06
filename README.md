# Directus silently uses Redis even when the operator has explicitly opted out

Minimal reproduction for a correctness bug in Directus 11.x.

Related upstream issue: [directus/directus#26535](https://github.com/directus/directus/issues/26535) (closed for lack of a deterministic repro — this repo provides one).

## The bug, in one sentence

`CACHE_STORE=memory` does not mean "no internal cache touches Redis": the [permissions cache](https://github.com/directus/directus/blob/main/api/src/permissions/cache.ts) selects its backend independently via [`redisConfigAvailable()`](https://github.com/directus/directus/blob/main/api/src/redis/utils/redis-config-available.ts), which switches to Redis the moment any `REDIS_*` env var is set, regardless of `CACHE_*`.

## Why this matters

This is a **contract violation**. The [docs](https://docs.directus.io/self-hosted/config-options.html#cache) say `CACHE_STORE` controls where cache data lives, and `CACHE_ENABLED=false` is documented as the off-switch. Neither is honored by the permissions cache. The actual off-switch is the undocumented `REDIS_ENABLED=false`.

The performance impact is a downstream consequence and is mitigable on the Redis side (separate DB per consumer, separate Redis instance) — but Directus shouldn't be silently joining a shared Redis in the first place when the operator's config says otherwise.

## Reproduction (~3 minutes)

Requirements: Docker, `bash`, `curl`.

```bash
docker compose up -d
scripts/reproduce.sh    # default 1,000,000 junk keys
```

Actual output on this machine (loopback Redis, 1M junk keys):

```
Step 1: baseline — Redis is empty
  PATCH /users/<id> (attach policy):  HTTP 200  TTFB=0.037s

Step 3: same PATCH, now against the populated Redis
  PATCH /users/<id> (attach policy):  HTTP 200  TTFB=13.807s
```

The point isn't the absolute number — it's that *Redis state affects request latency at all*, given the operator's `CACHE_*` config.

On every policy/role edit, Directus calls `clearCache()` → [`KvRedis.clear()`](https://github.com/directus/directus/blob/main/packages/memory/src/kv/lib/redis.ts), which issues `SCAN 0 MATCH permissions:*` and walks the cursor across the entire Redis keyspace. While the slow PATCH is in flight:

```bash
docker compose exec redis redis-cli -a redispw --no-auth-warning MONITOR | grep -i scan
# "SCAN" "0" "MATCH" "permissions:*"
# "SCAN" "1090503" "MATCH" "permissions:*"
# ...
```

— Directus's permissions cache, talking to Redis, despite `CACHE_STORE=memory`.

## Workaround

```bash
docker compose -f docker-compose.yml -f docker-compose.fix.yml up -d
scripts/reproduce.sh
```

Adds `REDIS_ENABLED=false`, which short-circuits `redisConfigAvailable()` so internal Directus subsystems fall back to in-memory. Sibling services that read `REDIS_HOST/PORT/PASSWORD` directly (e.g. a BullMQ job producer) are unaffected.

## Suggested upstream fix

1. **Respect the operator's cache configuration.** When `CACHE_STORE=memory`, no internal Directus cache should select Redis, regardless of which other `REDIS_*` vars exist.
2. **Document `REDIS_ENABLED=false`** in the cache docs as the supported way to keep Directus off Redis while leaving `REDIS_*` set for sibling services.
3. **Make `KvRedis.clear()` cheaper** by tracking namespace keys instead of `SCAN MATCH` over the whole keyspace — secondary, since an O(1) `clear()` doesn't fix the contract violation.

Tested on Directus `11.17.3` (architecture unchanged on `main` as of 2026-05), Redis `7-alpine`, Postgres `16-alpine`.
