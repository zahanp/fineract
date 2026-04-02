# Blue-Green Deployment Simulation — Apache Fineract (Docker)

## Current State

| Container | Image | Port | Role |
|---|---|---|---|
| `fineract-fineract-1` | `fineract:latest` | 8443 | **Blue** (live) |
| `fineract-db-1` | `postgres:18.3` | 5432 | Shared DB |
| `prometheus` | `prom/prometheus:v2.47.2` | 9090 | Metrics scrape |
| `grafana` | `grafana/grafana-oss:10.2.0` | 3000 | Dashboard |
| `loki` | `grafana/loki:2.9.2` | 3100 | Log aggregation |

All containers share the `fineract_default` bridge network.

---

## Architecture

```
Traffic Simulator (localhost:8080)
        |
        v
  [nginx proxy :8443]  <-- cutover point
     /          \
 [blue :18443]  [green :18444]
     \          /
   [postgres :5432]  <-- shared, no migration needed
```

The proxy on port 8443 is the single cutover point. Blue and green both connect
to the same PostgreSQL instance. Since this is a simulation using the same image,
"green" represents a new deployment version.

---

## Game Plan

### Phase 0 — Preparation

- [ ] **P0.1** Add nginx reverse proxy to `docker-compose-postgresql.yml`
  - Listens on `:8443` (takes over from blue)
  - Blue moves to internal port `:18443`
  - Green will be assigned internal port `:18444`
  - Config file: `config/docker/nginx/nginx.conf`

- [ ] **P0.2** Update Prometheus scrape target
  - Change `fineract-server:8443` → `nginx:8443` (proxy)
  - Or add both blue/green as separate scrape jobs for side-by-side comparison

- [ ] **P0.3** Confirm traffic simulator is running and baseline metrics are visible
  - Verify Grafana shows steady request rate before starting

---

### Phase 1 — Deploy Green

- [ ] **P1.1** Add `fineract-green` service to compose
  - Same `fineract:latest` image
  - Same env files as blue
  - Internal port `:18444` (not exposed to host)
  - Network alias: `fineract-green`

- [ ] **P1.2** Start green without touching blue
  ```bash
  docker-compose -f docker-compose-postgresql.yml up -d fineract-green
  ```

- [ ] **P1.3** Health check green directly
  ```bash
  curl -sk https://localhost:18444/fineract-provider/actuator/health
  ```
  Wait for `{"status":"UP"}` before proceeding.

---

### Phase 2 — Cutover

- [ ] **P2.1** Watch Grafana error rate panel — note baseline
- [ ] **P2.2** Switch nginx upstream from `blue` to `green`
  - Edit `nginx.conf`: change `proxy_pass` target
  - Reload nginx (zero-downtime): `docker exec nginx nginx -s reload`
- [ ] **P2.3** Confirm traffic is now hitting green
  ```bash
  curl -sk https://localhost:8443/fineract-provider/actuator/health
  # check container logs to confirm green is receiving requests
  docker logs fineract-green --tail 20 -f
  ```
- [ ] **P2.4** Monitor Grafana for 2-3 minutes
  - Error rate should stay flat
  - Request count should be uninterrupted

---

### Phase 3 — Validation

- [ ] **P3.1** Run a functional smoke test against the proxy
  ```bash
  curl -sk -u mifos:password \
    -H "Fineract-Platform-TenantId: default" \
    https://localhost:8443/fineract-provider/api/v1/offices
  ```
  Expect a valid JSON response with office data.

- [ ] **P3.2** Check Prometheus shows green as healthy scrape target
  - Navigate to http://localhost:9090/targets

- [ ] **P3.3** Confirm blue is idle (no incoming traffic)
  ```bash
  docker logs fineract-fineract-1 --tail 20
  ```

---

### Phase 4 — Rollback (if needed)

If anything goes wrong in Phase 2 or 3:

- [ ] **R1** Switch nginx upstream back to `blue`
  - Edit `nginx.conf`, reload: `docker exec nginx nginx -s reload`
- [ ] **R2** Confirm traffic returns to blue via logs and Grafana
- [ ] **R3** Stop green: `docker-compose -f docker-compose-postgresql.yml stop fineract-green`
- [ ] **R4** Investigate root cause before re-attempting

---

### Phase 5 — Decommission Blue

Only after green is stable for a defined soak period (e.g. 10 minutes in simulation):

- [ ] **P5.1** Stop blue container
  ```bash
  docker-compose -f docker-compose-postgresql.yml stop fineract
  ```
- [ ] **P5.2** Confirm system is fully operational on green only
- [ ] **P5.3** Remove blue from compose (optional cleanup)

---

## Observability Checkpoints

| Checkpoint | Where to look | Pass condition |
|---|---|---|
| Green is healthy pre-cutover | `curl :18444/actuator/health` | `status: UP` |
| Error rate stable during cutover | Grafana → error rate panel | No spike |
| Requests uninterrupted | Grafana → num requests panel | Continuous |
| Green receiving traffic post-cutover | `docker logs fineract-green` | Request logs visible |
| Prometheus scraping green | http://localhost:9090/targets | `health: up` |

---

## Risks & Mitigations

| Risk | Mitigation |
|---|---|
| Green fails health check | Don't proceed to cutover; keep blue live |
| Error spike during nginx reload | nginx reload is graceful — in-flight requests complete on blue |
| DB migration mismatch | Not applicable here (same image, same schema) |
| Prometheus loses scrape target | Update scrape config to include both blue and green during overlap |

---

## Notes

- This is a **same-image simulation** — blue and green run identical `fineract:latest`
- In a real deployment, green would use a newer image tag
- The shared PostgreSQL instance means no data migration is needed here
- In production, a load balancer (AWS ALB, nginx, Traefik) replaces the nginx container