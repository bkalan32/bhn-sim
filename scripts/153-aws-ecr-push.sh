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
#   ./scripts/153-aws-ecr-push.sh              build + push all five
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
    aws ecr describe-images --repository-name "bhn-sim/$svc" --query 'sort_by(imageDetails,&imagePushedAt)[-3:].[join(`,`,imageTags||[`<untagged>`]),imageSizeInBytes,imageScanStatus.status,imageScanFindingsSummary.findingSeverityCounts]' --output json 2>/dev/null \
      | python3 -c '
import json,sys
svc=sys.argv[1]
for tags,size,scan,sev in json.load(sys.stdin):
    print("  %-13s %-14s %5.0f MB  scan=%-11s %s" % (svc, tags, size/1e6, scan, json.dumps(sev or {})))' "$svc" || warn "  $svc: no images"
    # architecture of the newest tag, from the manifest
    tag=$(aws ecr describe-images --repository-name "bhn-sim/$svc" --query 'sort_by(imageDetails,&imagePushedAt)[-1].imageTags[0]' --output text 2>/dev/null || true)
    [[ -n "$tag" && "$tag" != None ]] && { arch=$(docker manifest inspect "$REG/bhn-sim/$svc:$tag" 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); m=d.get("manifests"); print(",".join(x["platform"]["architecture"] for x in m) if m else "(single-arch image: inspect config)")' 2>/dev/null || echo "?"); say "    newest $tag  arch=$arch"; }
  done
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
  step "$svc:$TAG -> $REG/bhn-sim/$svc:$TAG  (linux/amd64)"
  T0=$(date +%s)
  docker buildx build --platform linux/amd64 --provenance=false -t "$REG/bhn-sim/$svc:$TAG" -t "$REG/bhn-sim/$svc:latest" --push "services/$svc" > "/tmp/push-$svc.log" 2>&1 \
    && ok "pushed in $(( $(date +%s) - T0 )) s" || { tail -12 "/tmp/push-$svc.log"; die "build/push failed for $svc"; }
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
