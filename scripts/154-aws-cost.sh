#!/usr/bin/env bash
# Day 15, Step 6 (and every morning of week 3) — the bill, read daily. Cost Explorer lags
# about 24 h, so today's number is really yesterday's; the habit of looking is the point.
# NOTE: each Cost Explorer API call costs $0.01. This script makes two.
#
#   ./scripts/154-aws-cost.sh            last 3 days by service, and what is running now
#   ./scripts/154-aws-cost.sh --row 15   print a docs/aws-costs.md table row for Day N
source "$(dirname "$0")/lib.sh"
require_aws
cd "$LAB_ROOT" || exit 1
START=$(date -d '3 days ago' +%F); END=$(date -d 'tomorrow' +%F)

step "Cost Explorer — last 3 days, by service (unblended, USD; lags ~24 h)"
if ! aws ce get-cost-and-usage --time-period "Start=$START,End=$END" --granularity DAILY --metrics UnblendedCost \
     --group-by Type=DIMENSION,Key=SERVICE --output json > /tmp/ce.json 2>/tmp/ce.err; then
  warn "Cost Explorer not answering: $(head -c 200 /tmp/ce.err)"
  say "  Enable it once: Billing and Cost Management > Cost Explorer > Launch. Data appears within 24 h."
  exit 0
fi
python3 - <<'PY'
import json
d=json.load(open('/tmp/ce.json'))
tot=0.0
for day in d["ResultsByTime"]:
    rows=[(g["Keys"][0], float(g["Metrics"]["UnblendedCost"]["Amount"])) for g in day["Groups"]]
    rows=[r for r in rows if r[1] >= 0.001]
    s=sum(r[1] for r in rows); tot+=s
    print("  %s  $%.3f" % (day["TimePeriod"]["Start"], s))
    for k,v in sorted(rows, key=lambda r:-r[1])[:6]: print("      %-40s $%.3f" % (k[:40], v))
print("  3-day total: $%.3f" % tot)
PY
step "Running right now (this is what tomorrow's number will be made of)"
say "  NAT gateways: $(aws ec2 describe-nat-gateways --filter 'Name=state,Values=available,pending' --query 'length(NatGateways)' --output text)   (~\$1.10/day each idle)"
say "  EIPs:         $(aws ec2 describe-addresses --query 'length(Addresses)' --output text)"
say "  EC2 running:  $(aws ec2 describe-instances --filters 'Name=instance-state-name,Values=running,pending' --query 'length(Reservations[].Instances[])' --output text)"
say "  EKS clusters: $(aws eks list-clusters --query 'length(clusters)' --output text 2>/dev/null || echo 0)"
say "  ELB/NLB:      $(aws elbv2 describe-load-balancers --query 'length(LoadBalancers)' --output text 2>/dev/null || echo 0)"
if [[ "${1:-}" == "--row" ]]; then
  D="${2:-15}"; Y=$(date -d yesterday +%F)
  YC=$(python3 -c 'import json; d=json.load(open("/tmp/ce.json")); r=[x for x in d["ResultsByTime"] if x["TimePeriod"]["Start"]=="'"$Y"'"]; print("%.2f" % sum(float(g["Metrics"]["UnblendedCost"]["Amount"]) for x in r for g in x["Groups"]))')
  echo; say "  row for docs/aws-costs.md (yesterday = $Y):"
  echo "| $D | $(cat "$LAB_ROOT/checkpoints/day$D-what-ran.txt" 2>/dev/null || echo '_what ran_') | _hours_ | \$$YC ($Y, Cost Explorer) | _notes_ |"
fi
