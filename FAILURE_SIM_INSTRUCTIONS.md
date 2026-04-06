# Failure Simulation Instructions — Blue-Green Deployment

Two scenarios are available. Both are runnable from a single script and produce
distinct, visually dramatic signals in Grafana — designed for live demonstration.

---

## Scenario 1 — Null Datasource (HikariCP pool init failure → HTTP 500 storm)

**What it simulates:** Green is deployed with a misconfigured `FINERACT_HIKARI_JDBC_URL`
pointing to a non-existent host. HikariCP cannot initialise its connection pool.
The Spring Boot port opens before the datasource is validated, so the `nc -z`
health check passes — a false positive. nginx cuts over, and every subsequent
request returns HTTP 500.

**Why this matters:** This is the #1 failure mode in container-based blue-green
deployments. A port-only health check is not sufficient to confirm application
readiness. The datasource must be validated before cutover.

### Pre-flight

Confirm blue is healthy and traffic is flowing:

```bash
curl -sk -u mifos:password \
  -H "Fineract-Platform-TenantId: default" \
  https://localhost:8443/fineract-provider/api/v1/offices
```

Open Grafana at http://localhost:3000 — verify a steady request rate baseline.

> **Prerequisite:** nginx must already be the cutover point (Phase 0 of
> `BLUE_GREEN_DEPLOYMENT.md`). Blue should be on internal port `:18443` with
> nginx forwarding `:8443` → blue.

### Run

```bash
cd /Users/Zahan/Desktop/Container/Gimic/GIMICService/PlayGround2/fineract
SCENARIO=1 ./scripts/simulate-bg-failure-null-db-pointer-and-liquibase-lock.sh
```

### What happens

| Step | What occurs |
|---|---|
| 1 | Green starts with `fineract-postgresql-green-broken-hikari.env` — JDBC URL points to `db-does-not-exist:5432` |
| 2 | HikariCP queues connection retries in the background, cannot reach the host |
| 3 | Spring Boot binds port `:8443` — `nc -z` health check reports **healthy** (false positive) |
| 4 | Script patches `nginx.conf` and reloads — all traffic now hits green |
| 5 | First real request triggers HikariCP to hand out a connection → `CannotGetJdbcConnectionException` → **HTTP 500** |
| 6 | Grafana error rate: 0% → 100% in one scrape interval |

### What to watch

- **Grafana error rate panel** → cliff edge to 100% the moment nginx reloads
- **HTTP status breakdown** → all 5xx, no 2xx
- **Green container logs** → `CannotGetJdbcConnectionException` / `HikariPool-1 - Exception during pool initialization`

```bash
docker logs fineract-green --tail 50 -f
```

### Rollback

```bash
# Flip nginx back to blue
docker exec nginx sed -i 's/fineract-green/fineract-server/g' /etc/nginx/nginx.conf
docker exec nginx nginx -s reload

# Stop broken green
docker-compose -f docker-compose-postgresql.yml stop fineract-green
```

Recovery is instant. nginx reload is graceful — in-flight blue requests complete normally.
Grafana error rate drops back to 0% within one scrape interval.

---

## Scenario 2 — Liquibase Changelog Lock Contention (green hangs → HTTP 502 cliff)

**What it simulates:** Green starts against the shared PostgreSQL instance while
`DATABASECHANGELOGLOCK` is held (dirtied manually to represent a blue crash that
left the lock unreleased). Green hangs indefinitely in lock-wait. The port never
opens. nginx upstream returns 502 Bad Gateway the moment traffic is switched.

**Why this matters:** The #2–3 failure mode, especially after crash recovery or
concurrent deployments. Unlike Scenario 1, there is no false positive — the health
check correctly never passes — but an impatient operator cutting over anyway
produces a full outage.

### Run

```bash
SCENARIO=2 ./scripts/simulate-bg-failure-null-db-pointer-and-liquibase-lock.sh
```

The script pre-seeds the lock:

```sql
UPDATE DATABASECHANGELOGLOCK
SET LOCKED = true, LOCKEDBY = 'blue-simulation', LOCKGRANTED = NOW()
WHERE ID = 1;
```

Then starts green and cuts over nginx before the health check confirms readiness.

### What to watch

- **Grafana request rate** → drops to 0 (port never opens, no responses at all)
- **Grafana error rate** → 100% 502s from nginx
- **Green container logs** → `Waiting for changelog lock...`

```bash
docker logs fineract-green --tail 50 -f
```

### Rollback

```bash
# Flip nginx back to blue
docker exec nginx sed -i 's/fineract-green/fineract-server/g' /etc/nginx/nginx.conf
docker exec nginx nginx -s reload

# Release the Liquibase lock
docker exec fineract-db-1 psql -U postgres -d fineract_tenants \
  -c "UPDATE DATABASECHANGELOGLOCK SET LOCKED=false WHERE ID=1;"

# Stop green
docker-compose -f docker-compose-postgresql.yml stop fineract-green
```

---

## Env files used

| File | Scenario |
|---|---|
| `config/docker/env/fineract-postgresql-green-broken-hikari.env` | Scenario 1 — bad JDBC URL |
| `config/docker/env/fineract-postgresql-green-liquibase-lock.env` | Scenario 2 — valid DB, lock contended |

---

## Recommended demo order

Run Scenario 1 first — the 500 storm is immediate and easy to explain.
Run Scenario 2 second — the 502 cliff and zero-request drop make a strong contrast.
Both rollbacks take under 10 seconds, keeping the demo tight.
