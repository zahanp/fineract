#!/usr/bin/env bash
# simulate-bg-failure-null-db-pointer-and-liquibase-lock.sh
#
# Simulates two traffic failure modes during blue-green cutover on Fineract (Docker).
#
#   SCENARIO=1  HikariCP null datasource  — green starts, port opens, health check
#               passes (false positive via nc -z), nginx cuts over, every request
#               returns HTTP 500 (CannotGetJdbcConnectionException).
#
#   SCENARIO=2  Liquibase changelog lock  — green hangs on startup because
#               DATABASECHANGELOGLOCK is held by blue. Port never opens.
#               nginx upstream returns HTTP 502 cliff the moment traffic is switched.
#
# Usage:
#   SCENARIO=1 ./scripts/simulate-bg-failure-null-db-pointer-and-liquibase-lock.sh
#   SCENARIO=2 ./scripts/simulate-bg-failure-null-db-pointer-and-liquibase-lock.sh
#
# Prerequisites:
#   - Blue (fineract-fineract-1) running and healthy on :8443
#   - nginx proxy in place per BLUE_GREEN_DEPLOYMENT.md Phase 0
#   - Grafana open at http://localhost:3000

set -euo pipefail

COMPOSE_FILE="docker-compose-postgresql.yml"
SCENARIO="${SCENARIO:-1}"
GREEN_SERVICE="fineract-green"

RED='\033[0;31m'
GRN='\033[0;32m'
YLW='\033[0;33m'
NC='\033[0m'

log()  { echo -e "${GRN}[SIM]${NC} $*"; }
warn() { echo -e "${YLW}[SIM]${NC} $*"; }
err()  { echo -e "${RED}[SIM]${NC} $*"; }

# ── Pick env file based on scenario ──────────────────────────────────────────
if [[ "$SCENARIO" == "1" ]]; then
  FAILURE_ENV="./config/docker/env/fineract-postgresql-green-broken-hikari.env"
  SCENARIO_NAME="Scenario 1 — Null Datasource: HikariCP pool init failure → HTTP 500 storm"
elif [[ "$SCENARIO" == "2" ]]; then
  FAILURE_ENV="./config/docker/env/fineract-postgresql-green-liquibase-lock.env"
  SCENARIO_NAME="Scenario 2 — Liquibase Changelog Lock Contention: green hangs → HTTP 502 cliff"
else
  err "SCENARIO must be 1 or 2"; exit 1
fi

log "=== FAILURE SIMULATION: $SCENARIO_NAME ==="
echo ""

# ── Scenario 2 pre-step: dirty the Liquibase changelog lock ──────────────────
if [[ "$SCENARIO" == "2" ]]; then
  warn "Pre-seeding Liquibase lock on shared PostgreSQL..."
  docker exec fineract-db-1 psql -U postgres -d fineract_tenants \
    -c "UPDATE DATABASECHANGELOGLOCK SET LOCKED=true, LOCKEDBY='blue-simulation', LOCKGRANTED=NOW() WHERE ID=1;" \
    2>/dev/null || warn "Lock table not yet present — green will contend on first startup"
  log "Changelog lock dirtied. Green will hang on Liquibase init."
fi

# ── Start broken green via inline compose override ───────────────────────────
log "Starting $GREEN_SERVICE with failure env: $FAILURE_ENV"

cat > /tmp/green-failure-override.yml <<EOF
version: "3.8"
services:
  fineract-green:
    extends:
      file: ./config/docker/compose/fineract.yml
      service: fineract
    ports: []
    depends_on:
      db:
        condition: service_healthy
    env_file:
      - ./config/docker/env/fineract.env
      - ./config/docker/env/fineract-common.env
      - ${FAILURE_ENV#./}
    networks:
      default:
        aliases:
          - fineract-green
EOF

docker compose -f "$COMPOSE_FILE" -f /tmp/green-failure-override.yml up -d fineract-green
log "Green container started with broken config."

# ── Wait phase — demonstrates the false-positive health check gap ─────────────
if [[ "$SCENARIO" == "1" ]]; then
  log "Waiting for green port :8443 to bind (nc -z check — will PASS despite broken DB)..."
  for i in $(seq 1 30); do
    if docker exec fineract-green nc -z localhost 8443 2>/dev/null; then
      log "Port open after ${i}s. A naive health check would approve cutover here."
      break
    fi
    sleep 1; printf "."
  done
  echo ""
elif [[ "$SCENARIO" == "2" ]]; then
  warn "Green port will NOT open — Liquibase is blocking on lock acquisition."
  warn "Simulating operator who cuts over without waiting for health confirmation..."
  sleep 5
fi

# ── Cut nginx over to green ───────────────────────────────────────────────────
log "Cutting nginx upstream: fineract-server → fineract-green"
docker exec nginx sed -i 's/fineract-server/fineract-green/g' /etc/nginx/nginx.conf
docker exec nginx nginx -s reload
log "Nginx reloaded. All traffic now hitting broken green."
echo ""

# ── Show the failure signal ───────────────────────────────────────────────────
warn "========================================="
warn " FAILURE ACTIVE — watch Grafana now"
warn " http://localhost:3000"
warn "========================================="
echo ""
log "Probing 5 requests to capture the error signal..."
for i in 1 2 3 4 5; do
  STATUS=$(curl -sk -o /dev/null -w "%{http_code}" \
    -u mifos:password \
    -H "Fineract-Platform-TenantId: default" \
    "https://localhost:8443/fineract-provider/api/v1/offices" || echo "000")
  echo "  Request $i → HTTP $STATUS"
  sleep 1
done

echo ""
log "=== ROLLBACK INSTRUCTIONS ==="
warn "1. Switch nginx back to blue:"
warn "   docker exec nginx sed -i 's/fineract-green/fineract-server/g' /etc/nginx/nginx.conf"
warn "   docker exec nginx nginx -s reload"
if [[ "$SCENARIO" == "2" ]]; then
  warn "2. Release Liquibase lock:"
  warn "   docker exec fineract-db-1 psql -U postgres -d fineract_tenants \\"
  warn "     -c \"UPDATE DATABASECHANGELOGLOCK SET LOCKED=false WHERE ID=1;\""
fi
warn "3. Stop broken green:"
warn "   docker compose -f $COMPOSE_FILE stop fineract-green"