#!/usr/bin/env bash
set -euo pipefail

IMAGE_NAME="${IMAGE_NAME:-citybike:v1}"
PROD_API_KEY="${PROD_API_KEY:-lab-only-secret-2026}"

cleanup() {
  docker rm -f citybike-gate >/dev/null 2>&1 || true
}

run_gate() {
  local gate="$1"
  local env="$2"
  local port="$3"
  local script="$4"

  cleanup
  echo
  echo "========== $gate =========="

  docker run -d --name citybike-gate \
    -p "${port}:4173" \
    -e APP_ENV="$env" \
    -e PROD_API_KEY="$PROD_API_KEY" \
    "$IMAGE_NAME" >/dev/null

  local ready=0
  for i in $(seq 1 20); do
    if curl -sf "http://localhost:${port}/health" >/dev/null; then
      ready=1
      break
    fi
    sleep 1
  done

  if [ "$ready" -ne 1 ]; then
    docker logs citybike-gate
    cleanup
    echo "FAILED: $gate service did not become healthy"
    exit 1
  fi

  TARGET_URL="http://localhost:${port}" IMAGE_NAME="$IMAGE_NAME" \
    bash "scripts/test-${script}.sh"

  cleanup
  echo "========== $gate GREEN =========="
}

echo "Promoting image: $IMAGE_NAME"

run_gate "GATE 1: STAGING" staging 4174 staging
run_gate "GATE 2: UAT" uat 4174 uat
run_gate "GATE 3: OAT" oat 4174 oat
run_gate "GATE 4: PREPROD" preprod 4174 preprod

echo
echo "========== GATE 5: PRODUCTION =========="
cleanup
docker rm -f citybike-prod >/dev/null 2>&1 || true
docker run -d --name citybike-prod \
  -p 4173:4173 \
  -e APP_ENV=production \
  -e PROD_API_KEY="$PROD_API_KEY" \
  "$IMAGE_NAME" >/dev/null

ready=0
for i in $(seq 1 20); do
  if curl -sf http://localhost:4173/health >/dev/null; then
    ready=1
    break
  fi
  sleep 1
done

if [ "$ready" -ne 1 ]; then
  docker logs citybike-prod
  exit 1
fi

TARGET_URL="http://localhost:4173" bash scripts/test-prod.sh
echo "========== GATE 5: PRODUCTION GREEN =========="
echo "ALL FIVE GATES PASSED for $IMAGE_NAME"
