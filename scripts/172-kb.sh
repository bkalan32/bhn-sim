#!/usr/bin/env bash
# Day 17, Part B — the knowledge base: validated, shipped to the bot, searchable.
#
#   ./scripts/172-kb.sh                   validate every kb/*.md (the shape is the contract), build/refresh
#                                         ConfigMap kb in payments, restart the bot to pick it up, prove /ai sees it
#   ./scripts/172-kb.sh --search "words"  what would the bot match for these symptoms? (the same scorer)
#   ./scripts/172-kb.sh --check           validate + what the running bot has mounted; no changes
#
# The bot reads /kb (a ConfigMap mount, optional: the bot must start without it). The
# copilot reads kb/ from the repo. Same parser, same scorer (services/incident-bot/kb.py).
# Maintenance rule (README): every incident review updates a KB entry or says why not.
source "$(dirname "$0")/lib.sh"
[[ "${1:-}" == --search ]] || require_cluster    # --search needs no cluster: the scorer runs on the repo's kb/
cd "$LAB_ROOT" || exit 1
export PYTHONPATH="$LAB_ROOT/services/incident-bot"

validate() {
  python3 - "$LAB_ROOT/kb" <<'PY'
import sys, kb
d = sys.argv[1]
try:
    entries = kb.load(d)
except kb.KBError as e:
    print("  FAIL %s" % e); sys.exit(1)
ids = [e["id"] for e in entries]
dup = {i for i in ids if ids.count(i) > 1}
if dup: print("  FAIL duplicate ids: %s" % ", ".join(sorted(dup))); sys.exit(1)
for e in sorted(entries, key=lambda e: e["id"]):
    print("  %s  %-58s tier %d  %d symptoms, %d checks, from %s" % (e["id"], e["title"][:58], e["tier"], len(e["symptoms"]), len(e["discriminating_checks"]), ", ".join(e["learned_from"])))
print("  %d entries valid" % len(entries))
PY
}

case "${1:-}" in
  --search)
    [[ -n "${2:-}" ]] || die "usage: $0 --search \"ActivationHighErrorRate fraud_service_timeout ...\""
    step "KB search (the scorer the bot and the copilot use)"
    python3 - "$LAB_ROOT/kb" "$2" <<'PY'
import sys, kb
hits = kb.search(sys.argv[2], sys.argv[1])
if not hits: print("  no entry scores >= 2.0 — 'no KB match' is the honest answer")
for h in hits: print("  %s  score %-5s %s  (tier %d; %s)" % (h["id"], h["score"], h["title"], h["tier"], ", ".join(h["learned_from"])))
PY
    exit 0 ;;
  --check)
    step "kb/*.md — shape"; validate || exit 1
    step "What the running bot has mounted (/ai)"
    bot_get /ai | python3 -c 'import json,sys; d=json.load(sys.stdin).get("kb") or {}; print("  dir %s  ok=%s  entries: %s %s" % (d.get("dir"), d.get("ok"), ", ".join(d.get("entries",[])) or "(none)", d.get("error","")))'
    exit 0 ;;
esac

step "1/3  kb/*.md — the shape is the contract (kb/README.md)"
validate || die "fix the file above; the bot's parser is this parser"

step "2/3  ConfigMap kb in $PAYMENTS_NS (one key per file; refreshed in place)"
k create configmap kb -n "$PAYMENTS_NS" --from-file="$LAB_ROOT/kb" --dry-run=client -o yaml | k apply -f - >/dev/null
N=$(k get configmap kb -n "$PAYMENTS_NS" -o jsonpath='{.data}' | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')
ok "configmap/kb: $N files (README.md included, skipped by the parser)"

step "3/3  The bot reads /kb"
if k get deploy incident-bot -n "$PAYMENTS_NS" >/dev/null 2>&1; then
  if k get deploy incident-bot -n "$PAYMENTS_NS" -o jsonpath='{.spec.template.spec.volumes[*].name}' | grep -qw kb; then
    # a ConfigMap mount updates in place within ~a minute; a restart makes "now" true
    k rollout restart deploy/incident-bot -n "$PAYMENTS_NS" >/dev/null
    k rollout status deploy/incident-bot -n "$PAYMENTS_NS" --timeout=120s >/dev/null && ok "bot restarted"
    sleep 3
    bot_get /ai | python3 -c 'import json,sys; d=json.load(sys.stdin).get("kb") or {}
print("  /ai kb: dir %s ok=%s entries: %s" % (d.get("dir"), d.get("ok"), ", ".join(d.get("entries",[])) or "(none)"))
sys.exit(0 if d.get("ok") and d.get("entries") else 1)' && ok "the bot sees the KB" || warn "the bot does not see the KB yet — is the running image the Day 17 build (kb.py, the /kb mount)? Jenkins deploy-service SERVICE=incident-bot, then $0 again"
  else
    warn "the running incident-bot Deployment has no kb volume: it predates Day 17. Ship the new build (Jenkins deploy-service SERVICE=incident-bot — the manifest change rides with it), then $0"
  fi
else warn "no incident-bot on $KUBE_CONTEXT"; fi
say ""
say "  Try it:  $0 --search \"ActivationHighErrorRate fraud_service_timeout\""
say "           python3 tools/copilot.py -q \"activation errors are up and the logs say fraud_service_timeout — what is this?\""
ok "Next: Jenkins deploy-service SERVICE=incident-bot (if not yet), then ./scripts/173-kb-drill.sh"
