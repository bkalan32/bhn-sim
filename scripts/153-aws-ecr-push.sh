#!/usr/bin/env bash
# Day 15, Step 5 — the five images into ECR, built for the nodes they will run on.
#
# The PDF's trap is Apple Silicon building arm64 images for amd64 nodes ("exec format
# error"). WSL on an x86 laptop builds amd64 natively — but --platform linux/amd64 stays,
# explicitly, because the day this repo is cloned on a Mac is the day the trap bites, and
# because saying the target platform out loud is the right habit (B2).
#
# Tags: the SAME tag each service runs on kind right now (activation:33, egift:0.1, ...),
# read from the cluster — so Day 16's k8s/aws manifests are the kind manifests with the
# registry prefix added and nothing else, and "what version is on EKS?" has the same answer
# as "what version is on kind?".
#
# Day 15 (D5): the IMAGE is the same too, not just the tag. The image kind runs is still in
# the local Docker daemon (that is how `kind load` got it), so it is retagged and pushed as-is
# after its architecture is read — a rebuild from today's source with whatever lock file is
# on disk would be a different image wearing the same tag. The build path (buildx,
# --platform linux/amd64) is the fallback when the daemon no longer has the image.
#
#   ./scripts/153-aws-ecr-push.sh              push all five (the images kind runs)
#   ./scripts/153-aws-ecr-push.sh activation   one service
#   ./scripts/153-aws-ecr-push.sh --verify     list what ECR holds, with architecture and scan status
source "$(dirname "$0")/lib.sh"
require_aws; require_docker; require_cluster
cd "$LAB_ROOT" || exit 1
REG=$(aws_registry)
SERVICES=(activation egift settlement incident-bot remediator)

live_tag() {  # the image tag the service runs on kind
  local svc="$1" img
  img=$(k get deploy "$svc" -n "$PAYMENTS_NS" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)
  [[ -n "$img" ]] || img=$(k get cronjob "$svc" -n "$PAYMENTS_NS" -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].image}' 2>/dev/null || true)
  printf '%s' "${img##*:}"
}

if [[ "${1:-}" == "--verify" ]]; then
  step "ECR contents ($REG)"
  for svc in "${SERVICES[@]}"; do
    aws ecr describe-images --repository-name "bhn-sim/$svc" --query 'sort_by(imageDetails,&imagePushedAt)[-3:].[join(`,`,imageTags||[`<untagged>`]),imageSizeInBytes,imagePushedAt]' --output json 2>/dev/null \
      | python3 -c '
import json,sys
svc=sys.argv[1]
for tags,size,at in json.load(sys.stdin):
    print("  %-13s %-14s %5.0f MB  pushed %s" % (svc, tags, size/1e6, str(at)[:16]))' "$svc" || warn "  $svc: no images"
    # the tag kind runs: its architecture (from the manifest — a list for multi-arch, the
    # descriptor for a single image) and its scan result (the findings call; describe-images'
    # imageScanStatus is empty for basic scanning)
    tag=$(live_tag "$svc"); [[ -n "$tag" ]] || continue
    arch=$(docker manifest inspect -v "$REG/bhn-sim/$svc:$tag" 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin)
if isinstance(d,list): print(",".join(x["Descriptor"]["platform"]["os"]+"/"+x["Descriptor"]["platform"]["architecture"] for x in d if x["Descriptor"].get("platform",{}).get("architecture")!="unknown"))
else: p=d["Descriptor"].get("platform",{}); print(p.get("os","?")+"/"+p.get("architecture","?"))' 2>/dev/null || echo "?")
    scan=$(aws ecr describe-image-scan-findings --repository-name "bhn-sim/$svc" --image-id imageTag="$tag" --query '[imageScanStatus.status, imageScanFindingsSummary.findingSeverityCounts]' --output json 2>/dev/null | python3 -c 'import json,sys; s,c=json.load(sys.stdin); print(s, json.dumps(c or {}))' 2>/dev/null || echo "no scan")
    [[ "$arch" == linux/amd64 ]] && say "    $svc:$tag  arch=$arch  scan=$scan" || warn "    $svc:$tag  arch=$arch — EKS nodes need linux/amd64"
  done
  dim "  <untagged> rows are superseded pushes; the lifecycle policy expires them after a day"
  exit 0
fi

step "Login to ECR (a 12-hour token from your SSO session; nothing stored in git)"
aws ecr get-login-password | docker login --username AWS --password-stdin "$REG" >/dev/null 2>&1 && ok "docker login $REG" || die "ECR login failed — aws sso login --profile $AWS_PROFILE ?"
docker buildx inspect bhn >/dev/null 2>&1 || docker buildx create --name bhn --use >/dev/null
docker buildx use bhn >/dev/null

ONLY="${1:-}"
for svc in "${SERVICES[@]}"; do
  [[ -z "$ONLY" || "$ONLY" == "$svc" ]] || continue
  TAG=$(live_tag "$svc"); [[ -n "$TAG" ]] || { warn "$svc: not deployed on kind — skipping (no tag to mirror)"; continue; }
  T0=$(date +%s)
  if docker image inspect "$svc:$TAG" >/dev/null 2>&1; then
    # the exact image kind runs: same layers, same digest family — push it, do not rebuild it
    ARCH=$(docker image inspect -f '{{.Os}}/{{.Architecture}}' "$svc:$TAG")
    step "$svc:$TAG -> $REG/bhn-sim/$svc:$TAG  (the image kind runs, $ARCH)"
    [[ "$ARCH" == linux/amd64 ]] || die "$svc:$TAG is $ARCH — EKS nodes are linux/amd64; rebuild it: docker image rm $svc:$TAG && $0 $svc"
    docker tag "$svc:$TAG" "$REG/bhn-sim/$svc:$TAG" && docker tag "$svc:$TAG" "$REG/bhn-sim/$svc:latest" || die "tag failed"
    { docker push "$REG/bhn-sim/$svc:$TAG" && docker push "$REG/bhn-sim/$svc:latest"; } > "/tmp/push-$svc.log" 2>&1 \
      && ok "pushed in $(( $(date +%s) - T0 )) s  $(grep -o 'sha256:[0-9a-f]\{12\}' "/tmp/push-$svc.log" | tail -1)" || { tail -8 "/tmp/push-$svc.log"; die "push failed for $svc"; }
  else
    # the daemon no longer has it (Jenkins built it elsewhere, or `docker image prune`): build,
    # for the nodes' platform, from source — and say so, because this image is NOT byte-identical
    step "$svc:$TAG -> $REG/bhn-sim/$svc:$TAG  (not in the local daemon: building linux/amd64 from source)"
    warn "$svc:$TAG rebuilt from services/$svc — same tag, not the same bytes as kind's copy"
    [[ -f "services/$svc/requirements.lock.txt" ]] || { ( cd "services/$svc" && python3 -m venv .venv && . .venv/bin/activate && pip install -q -r requirements.txt && { grep -q opentelemetry-distro requirements.txt && opentelemetry-bootstrap -a install -q 2>/dev/null; true; } && pip freeze > requirements.lock.txt ) || die "could not generate services/$svc/requirements.lock.txt"; }
    docker buildx build --platform linux/amd64 --provenance=false --build-arg "APP_VERSION=$TAG" -t "$REG/bhn-sim/$svc:$TAG" -t "$REG/bhn-sim/$svc:latest" --push "services/$svc" > "/tmp/push-$svc.log" 2>&1 \
      && ok "built and pushed in $(( $(date +%s) - T0 )) s" || { tail -12 "/tmp/push-$svc.log"; die "build/push failed for $svc"; }
  fi
done

[[ -z "$ONLY" ]] && printf 'pushed %s to %s (ECR): %s\n' "$(date -u +%FT%TZ)" "$REG" "$(for s in "${SERVICES[@]}"; do printf '%s:%s ' "$s" "$(live_tag "$s")"; done)" > "$LAB_ROOT/checkpoints/day15-ecr-pushed.txt"

step "Scan on push — the first 'why is security asking about our base image' ticket"
sleep 5
for svc in "${SERVICES[@]}"; do
  [[ -z "$ONLY" || "$ONLY" == "$svc" ]] || continue
  TAG=$(live_tag "$svc"); [[ -n "$TAG" ]] || continue
  S=$(aws ecr describe-image-scan-findings --repository-name "bhn-sim/$svc" --image-id imageTag="$TAG" --query '[imageScanStatus.status, imageScanFindingsSummary.findingSeverityCounts]' --output json 2>/dev/null | python3 -c 'import json,sys; s,c=json.load(sys.stdin); print(s, json.dumps(c or {}))' 2>/dev/null || echo "PENDING")
  say "  $svc:$TAG  $S"
done
dim "  (scans finish within a minute; $0 --verify re-reads them. Skim one report in the console — Amazon ECR > repository > image > Vulnerabilities.)"
ok "Next: ./scripts/154-aws-cost.sh, then the README section, then commit"
