#!/usr/bin/env bash
# Day 6, Step 1 — rebuild Jenkins with docker, kubectl and kind, on the kind network.
# Your Day 1 jobs and plugins survive: jenkins_home is the same volume.
source "$(dirname "$0")/lib.sh"
require_docker; require_cluster
cd "$LAB_ROOT" || exit 1

step "Internal kubeconfig (points at the node container's name on the kind network)"
kind get kubeconfig --internal --name "$CLUSTER_NAME" > ci/kubeconfig-internal.yaml
grep -q '^ci/kubeconfig-internal.yaml' .gitignore || echo 'ci/kubeconfig-internal.yaml' >> .gitignore
ok "ci/kubeconfig-internal.yaml (gitignored — it contains cluster credentials)"
dim "The normal kubeconfig says 127.0.0.1:<random port>. From inside a container that is the"
dim "container itself. --internal says https://bhn-sim-control-plane:6443, which Docker DNS resolves."

step "Building jenkins-lab image (jenkins/jenkins:lts + docker + kubectl + kind + terraform; ~2-4 min first time)"
# Not -q: if a tool install fails you want to SEE it, not a green tick over a broken image.
docker build -t jenkins-lab -f ci/Dockerfile.jenkins ci/ 2>&1 | grep -E '^(Step|#[0-9]+ (DONE|ERROR)|.*version|.*Docker version|.*kind v)' | sed 's/^/  /' || true
docker image inspect jenkins-lab >/dev/null 2>&1 || die "image build failed — scroll up for the failing step"
# Prove the tools are in the image BEFORE replacing the running container.
for tool in docker kubectl kind git python3 terraform; do
  docker run --rm --entrypoint sh jenkins-lab -c "command -v $tool" >/dev/null 2>&1 || die "$tool missing from the built image"
done
ok "built — docker, kubectl, kind, git, python3, terraform all present"

step "Replacing the Day 1 container"
docker rm -f jenkins >/dev/null 2>&1 || true
# ALLOW_LOCAL_CHECKOUT: the git plugin refuses to clone from a local path (like /repo)
# by default — a 2022 hardening, since a local checkout could read anything on the
# controller. Lab-only; in production the SCM is a real remote.
docker run -d --name jenkins --network kind -u root \
  -p 8081:8080 -p 50000:50000 \
  --restart unless-stopped \
  -e JAVA_OPTS="-Dhudson.plugins.git.GitSCM.ALLOW_LOCAL_CHECKOUT=true" \
  -v jenkins_home:/var/jenkins_home \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$LAB_ROOT":/repo \
  -v "$LAB_ROOT/ci/kubeconfig-internal.yaml":/root/.kube/config:ro \
  jenkins-lab >/dev/null
ok "jenkins running on :8081, /repo = $LAB_ROOT"
warn "LAB SHORTCUT: root + Docker socket mounted = root on the host. Never in production. It is in the README."

step "Waiting for Jenkins to answer"
for _ in $(seq 1 60); do curl -fsS -o /dev/null http://localhost:8081/login 2>/dev/null && break; sleep 3; done

step "Can it reach the cluster and Docker?"
docker exec jenkins kubectl get nodes --no-headers 2>&1 | sed 's/^/  /' \
  && ok "kubectl works inside jenkins" || die "kubectl inside jenkins failed — is the container on the kind network? docker inspect jenkins | grep -A3 Networks"
docker exec jenkins docker ps --format '  {{.Names}}' 2>&1 | head -3 \
  && ok "docker works inside jenkins" || die "docker socket not usable inside jenkins"
if OUT=$(docker exec jenkins git -C /repo log -1 --format='  repo HEAD: %h %s' 2>&1); then
  echo "$OUT"; ok "git can read /repo"
elif echo "$OUT" | grep -q 'not a git repository'; then
  die "$LAB_ROOT is not a git repository yet. Run:  git init -b main && git add -A && git commit -m 'lab state'"
elif echo "$OUT" | grep -q 'dubious ownership'; then
  die "git dubious-ownership — the Dockerfile's safe.directory setting did not apply; rebuild the image"
else
  die "git failed: $OUT"
fi

step "Next: create the pipeline job"
say "  http://localhost:8081  ->  New Item  ->  name: deploy-service  ->  Pipeline  ->  OK"
say "  Definition: Pipeline script from SCM"
say "    SCM: Git    Repository URL: /repo    Branch: */main    Script Path: Jenkinsfile"
say "  Save. Then Build with Parameters."
dim "Or: ./scripts/52-jenkins-job.sh   (creates it via the API if you give it your admin password)"
