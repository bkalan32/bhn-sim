#!/usr/bin/env bash
# Day 2, Steps 1-3 — venv, dependencies, container image, load into kind.

source "$(dirname "$0")/lib.sh"
require_docker

SVC_DIR="$LAB_ROOT/services/activation"
cd "$SVC_DIR" || die "services/activation not found"

step "Python virtual environment"
if [[ ! -d .venv ]]; then
  python3 -m venv .venv || die "python3-venv missing. Run: sudo apt-get install -y python3-venv"
fi
# shellcheck disable=SC1091
source .venv/bin/activate
pip install --upgrade pip --quiet
pip install --quiet -r requirements.txt
pip freeze > requirements.lock.txt
ok "dependencies installed; pinned into requirements.lock.txt"
dim "$(grep -iE '^(fastapi|uvicorn|prometheus-client)' requirements.lock.txt | tr '\n' ' ')"

step "Quick local sanity check (no cluster involved)"
# Start the real server on a scratch port and exercise it with curl.
# FIX: this used fastapi.testclient, which pulls in httpx as a hidden extra
# dependency (recent starlette wants httpx2). Using the actual server over HTTP
# needs nothing beyond what the service already requires -- and it tests the same
# path uvicorn will take in the container.
SANITY_PORT="${SANITY_PORT:-8123}"
if ss -ltn 2>/dev/null | grep -q ":${SANITY_PORT} "; then
  die "Port ${SANITY_PORT} is busy. Re-run with: SANITY_PORT=8124 $0"
fi

UV_PID=""
sanity_cleanup() { [[ -n "$UV_PID" ]] && kill "$UV_PID" 2>/dev/null || true; }
trap sanity_cleanup EXIT INT TERM

python3 -m uvicorn app:app --host 127.0.0.1 --port "$SANITY_PORT" --log-level warning \
  >/tmp/activation-sanity.log 2>&1 &
UV_PID=$!

for _ in $(seq 1 40); do
  curl -fsS "http://127.0.0.1:${SANITY_PORT}/healthz" >/dev/null 2>&1 && break
  kill -0 "$UV_PID" 2>/dev/null || die "uvicorn died on startup. Log: $(cat /tmp/activation-sanity.log)"
  sleep 0.5
done

curl -fsS "http://127.0.0.1:${SANITY_PORT}/healthz" >/dev/null 2>&1 \
  || die "/healthz never answered. Log: $(cat /tmp/activation-sanity.log)"
ok "/healthz answers"

BODY='{"card_number":"6011000012345678","amount":50,"store_id":"STORE-0421"}'
OKS=0; ERRS=0
for _ in $(seq 1 40); do
  CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
         "http://127.0.0.1:${SANITY_PORT}/activate" \
         -H 'Content-Type: application/json' -d "$BODY")
  case "$CODE" in 200) OKS=$((OKS+1));; *) ERRS=$((ERRS+1));; esac
done
(( OKS > 0 )) || die "40 requests and not one success. Log: $(cat /tmp/activation-sanity.log)"
ok "/activate: ${OKS} ok, ${ERRS} error (ERROR_RATE defaults to 2%, so a few errors are correct)"

METRICS=$(curl -fsS "http://127.0.0.1:${SANITY_PORT}/metrics")
for m in activation_requests_total activation_latency_seconds_bucket activation_build_info; do
  grep -q "^${m}" <<<"$METRICS" || die "/metrics is missing ${m}"
done
ok "/metrics exposes all three metric families"
dim "$(grep '^activation_requests_total{' <<<"$METRICS" | tr '\n' ' ')"

kill "$UV_PID" 2>/dev/null || true
UV_PID=""
trap - EXIT INT TERM

step "Building the image"
dim "The tag IS a version. 'What version is running right now' is one of the first"
dim "questions asked on an incident bridge — make it answerable."
docker build --build-arg "APP_VERSION=${APP_TAG}" -t "${APP_IMAGE}:${APP_TAG}" .
ok "built ${APP_IMAGE}:${APP_TAG}"

step "Loading the image into kind"
dim "kind runs its own container registry-less node; it cannot see your local Docker"
dim "images unless you explicitly load them. Forgetting this is ErrImagePull."
kind load docker-image "${APP_IMAGE}:${APP_TAG}" --name "$CLUSTER_NAME"
ok "Next: scripts/11-deploy-activation.sh"
