# Directus permissions-cache forces Redis even when the operator has explicitly opted out

Minimal reproduction for a long-standing performance issue in Directus 11.x: editing access policies takes **seconds to minutes** of TTFB on installations that share a Redis instance with anything else (BullMQ, sidecar workers, an app that simply reuses the same Redis box). The slowdown scales linearly with the **total** number of keys in the Redis database, even though the user has set `CACHE_ENABLED=false` and `CACHE_STORE=memory`.

Related upstream issue: [directus/directus#26535](https://github.com/directus/directus/issues/26535) (closed for lack of a deterministic repro — this repo provides one).

## TL;DR

- `CACHE_ENABLED=false` + `CACHE_STORE=memory` is **not** sufficient to keep Directus off Redis.
- The permissions cache (`api/src/permissions/cache.ts`) is a separate cache instance that ignores `CACHE_*` settings entirely. Its backend is selected by [`redisConfigAvailable()`](https://github.com/directus/directus/blob/main/api/src/redis/utils/redis-config-available.ts), which returns `true` if **any** `REDIS_*` env var is set.
- On every policy/role edit, Directus calls `clearCache()` → [`KvRedis.clear()`](https://github.com/directus/directus/blob/main/packages/memory/src/kv/lib/redis.ts), which issues `SCAN MATCH permissions:*` over the **entire** Redis keyspace. With millions of unrelated keys (BullMQ jobs, an unrelated app, etc.), this iteration takes seconds-to-minutes per write, blocking admin workflows.
- The undocumented escape hatch is **`REDIS_ENABLED=false`**. It short-circuits `redisConfigAvailable()` and forces all internal Directus caches back to local in-memory storage, while leaving your own `REDIS_*` env vars in place (so sibling services that read them, like a BullMQ worker, keep working).

## Reproduction (~3 minutes)

Requirements: Docker, `bash`, `curl`, `jq`.

```bash
git clone <this repo>
cd <this repo>

# Bring up the buggy stack (CACHE_ENABLED=false, CACHE_STORE=memory, REDIS_HOST set)
docker compose up -d

# Reproduce: prints the TTFB before and after Redis is populated with junk
scripts/reproduce.sh           # default 1,000,000 keys; pass another number to scale
```

Expected output (timings on a modern laptop, single-host, lo loopback):

```
Step 1: baseline — Redis is empty
  PATCH /users/<id> (attach policy):  HTTP 200  TTFB=0.025s  total=0.025s

Step 2: pump 1000000 junk keys into Redis
  ... DBSIZE=1000000

Step 3: same PATCH, now against the populated Redis
  PATCH /users/<id> (attach policy):  HTTP 200  TTFB=4.6s  total=4.6s
```

Scale `NUM_KEYS` and the slowdown scales linearly:

| Junk keys in Redis | TTFB on PATCH /users/:id |
|--------------------|--------------------------|
| 0                  | ~25ms                    |
| 500,000            | ~2.3s                    |
| 1,000,000          | ~4.5s                    |
| 2,000,000          | ~9s                      |

(Slower in production because Redis is on the network, not loopback. In the original report this was 47s against a Redis with ~2.2M BullMQ keys.)

## Verifying the smoking gun

Watch the Redis traffic during the slow PATCH:

```bash
docker compose exec redis redis-cli -a redispw --no-auth-warning MONITOR | grep -i scan
```

You will see thousands of lines like:

```
"SCAN" "0" "MATCH" "permissions:*"
"SCAN" "1090503" "MATCH" "permissions:*"
"SCAN" "1745863" "MATCH" "permissions:*"
...
```

Almost every response is empty (`*0` in RESP). The cursor walks the entire keyspace because of how `SCAN` works — `MATCH` filters client-side.

Equivalent view via `strace` on the Directus worker (inside the container):

```
write(fd, "*4\r\n$4\r\nscan\r\n$7\r\n1090503\r\n$5\r\nMATCH\r\n$13\r\npermissions:*\r\n", 58)
read(fd,  "*2\r\n$7\r\n1745863\r\n*0\r\n", 65536) = 21
```

## Verifying the workaround

The `docker-compose.fix.yml` override sets `REDIS_ENABLED=false` on the Directus service:

```bash
docker compose down
docker compose -f docker-compose.yml -f docker-compose.fix.yml up -d
scripts/reproduce.sh        # same NUM_KEYS as before
```

Step 3 should now match Step 1: TTFB drops back to ~25ms regardless of how many keys are in Redis.

## Why the existing config is misleading

The Directus [cache docs](https://docs.directus.io/self-hosted/config-options.html#cache) say:

> `CACHE_STORE` — Where to store the cache data. Either `memory`, `redis`. — default: `memory`

A reasonable operator concludes that with `CACHE_ENABLED=false` and `CACHE_STORE=memory`, no Directus cache touches Redis. That is **incorrect** for the permissions cache, which selects its backend independently and silently switches to Redis the moment any `REDIS_*` env var exists. Setting `CACHE_PERMISSIONS=false` (suggested in some forum posts) is a no-op — that variable does not exist in Directus 11.x.

## Suggested upstream fixes (in priority order)

1. **Honor `CACHE_STORE`** in `redisConfigAvailable()` (or wherever the permissions cache picks its backend). If the operator has set `CACHE_STORE=memory`, the permissions cache should be in-memory too.
2. **Introduce per-cache backend overrides** like `CACHE_PERMISSIONS_STORE=memory`, and document them. Several users have intuited that this variable should exist.
3. **Document `REDIS_ENABLED=false`** as the supported way to keep Directus's internal subsystems off Redis while leaving `REDIS_*` env vars available for sibling services.
4. **Use `UNLINK` over keyspace** isn't the answer — even if Directus avoided the actual deletion call, the `SCAN` itself is what's expensive on shared Redis. The right fix is at backend selection, not at the clear-implementation level.

## Files

- [`docker-compose.yml`](docker-compose.yml) — Postgres, Redis, Directus 11.17.3 with the misleading "cache off" env.
- [`docker-compose.fix.yml`](docker-compose.fix.yml) — adds `REDIS_ENABLED=false` to demonstrate the workaround.
- [`scripts/setup.sh`](scripts/setup.sh) — waits for Directus, creates a test user and a test policy.
- [`scripts/pump-redis.sh`](scripts/pump-redis.sh) — fills Redis with N junk keys (`bull:queue:*`).
- [`scripts/reproduce.sh`](scripts/reproduce.sh) — runs the full before/after comparison.

## Tested versions

- Directus `11.17.3` (issue is present in all 11.x versions checked; permissions cache architecture is unchanged on `main` as of 2026-05).
- Redis `7-alpine`, Postgres `16-alpine`.
