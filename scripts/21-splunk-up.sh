#!/usr/bin/env bash
# Day 3, Step 2 — run Splunk on the kind Docker network so pods can reach it.
#
# ⚠️ THIS STARTS THE 60-DAY TRIAL CLOCK. Do not run it until you are actually doing
# Day 3. Both the Enterprise Trial and the Free licence index 500 MB/day; the trial
# buys you ALERTING and 60 days, not more volume. Do your Splunk alerting work inside
# the window, because Free cannot run alerts at all.

source "$(dirname "$0")/lib.sh"
require_docker

step "Memory check"
MEM_GB=$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 / 1024 ))
say "  WSL sees ${MEM_GB} GB"
if (( MEM_GB < 10 )); then
  warn "Splunk wants ~2 GB on top of the cluster, monitoring stack and Jenkins."
  warn "If pods start getting evicted, stop Jenkins for today:  docker stop jenkins"
fi

step "Checking port 8000"
if ss -ltn 2>/dev/null | grep -q ':8000 '; then
  warn "Port 8000 is in use. Splunk's web UI wants it."
  dim  "Day 2 used :8000 for a port-forward, but we moved traffic to the NodePort on"
  dim  ":30080, so nothing here should need it. Find the holder: ss -ltnp | grep 8000"
  die  "Free port 8000, then re-run."
fi

step "Starting Splunk"
if docker ps -a --format '{{.Names}}' | grep -qx "$SPLUNK_CONTAINER"; then
  docker start "$SPLUNK_CONTAINER" >/dev/null
  ok "existing container started"
else
  # Pinned tag, not :latest. The PDF uses splunk/splunk:latest, which contradicts its
  # own Day 2 lesson that the tag IS a version — and means a rebuild months from now
  # silently gives you a different Splunk. (CORRECTIONS-DAY3.md B6)
  docker run -d --name "$SPLUNK_CONTAINER" --network kind \
    -p 8000:8000 -p 8088:8088 \
    -e SPLUNK_START_ARGS=--accept-license \
    -e "SPLUNK_PASSWORD=${SPLUNK_PASSWORD}" \
    --memory 3g \
    splunk/splunk:9.4 >/dev/null || die "docker run failed. Is the 'kind' network present? (docker network ls)"
  ok "container created from splunk/splunk:9.4"
fi

step "Waiting for Splunk to finish first boot (2-4 minutes)"
dim "Watching for 'Ansible playbook complete'. Follow along in another terminal with:"
dim "  docker logs -f splunk"
for i in $(seq 1 90); do
  if docker logs "$SPLUNK_CONTAINER" 2>&1 | grep -q "Ansible playbook complete"; then
    ok "Splunk is up (after ~$((i*5))s)"; break
  fi
  docker ps --format '{{.Names}}' | grep -qx "$SPLUNK_CONTAINER" \
    || die "Splunk container exited. Check: docker logs $SPLUNK_CONTAINER | tail -40"
  sleep 5
  (( i % 12 == 0 )) && printf '  still starting... %ss\n' "$((i*5))"
done

IP="$(splunk_ip || true)"
step "Details you need next"
say "  Web UI    http://localhost:8000"
say "  Username  admin"
say "  Password  ${SPLUNK_PASSWORD}"
say "  HEC port  8088"
say "  IP on the kind network   ${IP:-<not found>}"
printf 'splunk admin / %s   ip=%s\n' "$SPLUNK_PASSWORD" "${IP:-unknown}" > "$CHECKPOINTS/day3-splunk.txt"
chmod 600 "$CHECKPOINTS/day3-splunk.txt"

step "Now create the HEC token, by hand, in the UI"
say "  1. Settings > Data Inputs > HTTP Event Collector > New Token"
say "  2. Name it 'k8s', accept the defaults, and COPY THE TOKEN VALUE at the end"
say "  3. On that same page: Global Settings > All Tokens = Enabled"
echo
dim "Step 3 is the one everyone forgets. A token that exists but is globally disabled"
dim "returns HTTP 403 and Fluent Bit logs it once, quietly."
dim "Also check the token's 'Allowed Indexes' includes main, or searches find nothing."
ok "Then: ./scripts/22-fluent-bit.sh <TOKEN>"
