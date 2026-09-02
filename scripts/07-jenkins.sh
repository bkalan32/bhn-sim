#!/usr/bin/env bash
# Day 1, Step 8 — Jenkins as a plain Docker container (deliberately NOT in the cluster).
#
# A large share of production incidents are caused by deployments, so understanding
# the pipeline is part of incident response. Today it only needs to exist.
#
# Port 8081 on the host is deliberate: Jenkins listens on 8080 internally, and 8080 on
# the host is used by the Step 5 smoke test.

source "$(dirname "$0")/lib.sh"
require_docker

step "Starting Jenkins"
if docker ps -a --format '{{.Names}}' | grep -qx jenkins; then
  docker start jenkins >/dev/null
  ok "existing 'jenkins' container started"
else
  docker run -d --name jenkins \
    --restart unless-stopped \
    -p 8081:8080 -p 50000:50000 \
    -v jenkins_home:/var/jenkins_home \
    jenkins/jenkins:lts >/dev/null
  ok "jenkins container created"
fi

step "Waiting for Jenkins to finish first boot"
for _ in $(seq 1 60); do
  if docker exec jenkins test -f /var/jenkins_home/secrets/initialAdminPassword 2>/dev/null; then
    break
  fi
  sleep 5
done

step "Unlock password"
if docker exec jenkins cat /var/jenkins_home/secrets/initialAdminPassword 2>/dev/null | tee "$CHECKPOINTS/day1-jenkins-unlock.txt"; then
  chmod 600 "$CHECKPOINTS/day1-jenkins-unlock.txt"
else
  warn "No unlock file. Either Jenkins is still booting (wait, re-run) or it is already set up."
fi

step "Next steps in the browser"
say "  1. Open http://localhost:8081"
say "  2. Paste the unlock password above"
say "  3. Install suggested plugins (needs internet, takes a few minutes)"
say "  4. Create ONE Freestyle job that runs: echo hello"
dim "Port 50000 is the agent port — not needed today, but opening it now saves a"
dim "container recreate when you add build agents later in the series."
ok "Next: scripts/08-checkpoint.sh"
