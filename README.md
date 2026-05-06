# Directus silently uses Redis even when the operator has explicitly opted out

Minimal reproduction for a correctness bug in Directus 11.x: setting `CACHE_ENABLED=false` and `CACHE_STORE=memory` is not honored by all of Directus's internal caches. The permissions cache silently switches to a Redis backend whenever **any** `REDIS_*` env var is present — typically because the operator wants Redis available for the cluster messenger or for a sibling service like BullMQ.

This is primarily a **contract violation**: the operator's explicit cache configuration is overridden without warning or documentation. The dramatic slowdown that some users observe (seconds to minutes per policy edit) is a downstream consequence — see [Performance consequence](#performance-consequence) below.

Related upstream issue: [directus/directus#26535](https://github.com/directus/directus/issues/26535) (closed for lack of a deterministic repro — this repo provides one).

## The bug, in one sentence

`CACHE_STORE=memory` does not mean "no internal cache touches Redis": the [permissions cache](https://github.com/directus/directus/blob/main/api/src/permissions/cache.ts) selects its backend independently via [`redisConfigAvailable()`](https://github.com/directus/directus/blob/main/api/src/redis/utils/redis-config-available.ts), which switches to Redis the moment any `REDIS_*` env var is set, regardless of `CACHE_*`.

## Why this matters even before performance

A reasonable operator who reads the [cache documentation](https://docs.directus.io/self-hosted/config-options.html#cache):

> `CACHE_STORE` — Where to store the cache data. Either `memory`, `redis`. — default: `memory`

…concludes that the default already keeps Directus's caches off Redis, and that explicitly setting `CACHE_ENABLED=false` is doubly safe. That reading is wrong, and there is nothing in the docs that flags it. Operational consequences of the silent Redis use:

- **Surprising operational coupling.** Anyone debugging Directus latency would not look at Redis when `CACHE_*` is "off." We didn't, until we ran `strace` on the production worker.
- **Surprising blast radius.** Any redeploy or restart of Redis affects Directus's policy-edit path even when the operator believes Redis is purely a sibling concern.
- **Surprising failure modes.** Permission writes can succeed in MySQL but fail to clear the Redis cache, leaving stale permissions for one cache TTL.
- **Undocumented escape hatch.** The actual off-switch is `REDIS_ENABLED=false`, which is not mentioned in the cache documentation. The variable that operators reasonably *expect* to exist (`CACHE_PERMISSIONS=false`, `CACHE_PERMISSIONS_STORE=memory`) doesn't.

## Performance consequence

When Redis is shared with another consumer that produces many keys (BullMQ jobs, a sibling app, anything in the same Redis DB), the cost of the silent Redis use becomes severe.

On every policy/role edit, Directus calls `clearCache()` → [`KvRedis.clear()`](https://github.com/directus/directus/blob/main/packages/memory/src/kv/lib/redis.ts), which issues `SCAN 0 MATCH permissions:*` and walks the cursor across the **entire** Redis keyspace. `SCAN` with `MATCH` is O(total keys), not O(matching keys), because the filter is applied client-side.

To be clear: this performance behavior is fundamentally a *Redis architecture* concern. Sharing a Redis database across tenants is a known footgun for any consumer that uses `KEYS`/`SCAN MATCH`, and the long-term right answer on the consumer's side is to give each subsystem its own DB or its own Redis instance. But the bug surface here is specifically about Directus *unexpectedly being one of those consumers* despite the operator's configuration saying otherwise.

| Junk keys in Redis | TTFB on PATCH /users/:id (loopback Redis) |
|--------------------|-------------------------------------------|
| 0                  | ~25ms                                     |
| 500,000            | ~2.3s                                     |
| 1,000,000          | ~4.5s                                     |
| 2,000,000          | ~9s                                       |

(Worse in production where Redis is on the network. The original report observed ~47s against ~2.2M BullMQ keys.)

## Reproduction (~3 minutes)

Requirements: Docker, `bash`, `curl`, `jq`.

```bash
git clone <this repo>
cd <this repo>

# Bring up the buggy stack — CACHE_ENABLED=false, CACHE_STORE=memory, REDIS_HOST set.
docker compose up -d

# Reproduce: prints TTFB for the policy-attach PATCH before and after Redis is populated.
scripts/reproduce.sh           # default 1,000,000 junk keys; pass another number to scale
```

Expected output:

```
Step 1: baseline — Redis is empty
  PATCH /users/<id> (attach policy):  HTTP 200  TTFB=0.025s

Step 2: pump 1000000 junk keys into Redis
  ...

Step 3: same PATCH, now against the populated Redis
  PATCH /users/<id> (attach policy):  HTTP 200  TTFB=4.5s
```

The point of the reproduction isn't the absolute number — it's that *Redis state affects request latency at all*, given the operator's `CACHE_*` config.

## Smoking gun

While the slow PATCH is in flight:

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

— Directus's permissions cache, talking to Redis, despite `CACHE_STORE=memory`.

## Verifying the workaround

The undocumented off-switch is `REDIS_ENABLED=false`. The override file demonstrates it:

```bash
docker compose down
docker compose -f docker-compose.yml -f docker-compose.fix.yml up -d
scripts/reproduce.sh
```

Step 3 should now match Step 1 — Redis is no longer in the path of the permissions cache.

`REDIS_ENABLED=false` short-circuits `redisConfigAvailable()`, so the permissions cache (and Directus's other internal Redis users, like the cluster messenger) fall back to in-memory. Sibling services that read `REDIS_HOST/PORT/PASSWORD` directly (e.g. a BullMQ worker in another container) are unaffected, because they don't go through `redisConfigAvailable()`.

## Suggested upstream fix

The fix is at the contract layer, not the performance layer:

**Primary — respect the operator's cache configuration.** When `CACHE_STORE=memory` is set, *no* internal Directus cache should select Redis as its backend, regardless of which other `REDIS_*` env vars exist. The current design treats `REDIS_HOST` as a global "Redis is available, feel free to use it" flag, which is at odds with the per-cache `CACHE_*` configuration that already exists.

**Secondary — document the actual off-switch.** Until the contract is fixed, the cache documentation should clearly state that `CACHE_STORE` does not control the permissions cache, and that `REDIS_ENABLED=false` is the supported way to keep all internal Directus subsystems off Redis while leaving `REDIS_*` env vars in place for sibling services.

**Tertiary — make the Redis-backed `clear()` cheaper.** If Redis is intentionally chosen, `KvRedis.clear()` could maintain its own tracking set/hash of namespace keys and use that for invalidation, avoiding the O(keyspace) `SCAN`. This is a worthwhile optimization but secondary — even an O(1) `clear()` doesn't make it correct for Directus to override an operator who said `CACHE_STORE=memory`.

## Files

- [`docker-compose.yml`](docker-compose.yml) — Postgres, Redis, Directus 11.17.3 with `CACHE_ENABLED=false`, `CACHE_STORE=memory`, and `REDIS_HOST` set.
- [`docker-compose.fix.yml`](docker-compose.fix.yml) — adds `REDIS_ENABLED=false` to demonstrate the workaround.
- [`scripts/setup.sh`](scripts/setup.sh) — waits for Directus, creates a test user and a test policy.
- [`scripts/pump-redis.sh`](scripts/pump-redis.sh) — fills Redis with N junk keys (`bull:queue:*`).
- [`scripts/reproduce.sh`](scripts/reproduce.sh) — runs the full before/after comparison.

## Tested versions

- Directus `11.17.3`. The permissions-cache architecture is unchanged on `main` as of 2026-05.
- Redis `7-alpine`, Postgres `16-alpine`.
