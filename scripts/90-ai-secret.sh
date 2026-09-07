#!/usr/bin/env bash
# Day 9, Step 1 — put the API key where the bot can read it and NOWHERE else.
#
#   ./scripts/90-ai-secret.sh              prompt for the key (not echoed), verify it, store it
#   ./scripts/90-ai-secret.sh --check      is the secret there, and does the key still work?
#   ./scripts/90-ai-secret.sh --remove     delete the secret (the bot keeps running without drafts)
#   ./scripts/90-ai-secret.sh --ollama URL use a local Ollama instead (no key), e.g. http://host.docker.internal:11434
#
# The key goes: your keyboard -> a Kubernetes Secret -> the pod's environment. It never
# touches a file in this repo, the shell history (read -s), or a build log.
source "$(dirname "$0")/lib.sh"
require_cluster
SECRET=ai-keys
MODEL_DEFAULT="claude-sonnet-4-5"

restart_bot() {
  # Env from a Secret is read at pod start; a changed secret needs a new pod.
  if k get deploy incident-bot -n "$PAYMENTS_NS" >/dev/null 2>&1; then
    k rollout restart deployment/incident-bot -n "$PAYMENTS_NS" >/dev/null
    k rollout status deployment/incident-bot -n "$PAYMENTS_NS" --timeout=120s >/dev/null && ok "incident-bot restarted with the new env"
  fi
}

verify_key() {
  # Two calls: /v1/models proves the key and shows what the account can use; a 5-token
  # message proves the configured model name is real. The PDF just hopes.
  local key="$1" model="$2" out code
  step "Verifying the key against api.anthropic.com"
  out=$(curl -sS -m 20 -w '\n%{http_code}' https://api.anthropic.com/v1/models \
        -H "x-api-key: $key" -H "anthropic-version: 2023-06-01" 2>/dev/null || true)
  code="${out##*$'\n'}"; out="${out%$'\n'*}"
  case "$code" in
    200) ok "key accepted (HTTP 200)"
         printf '%s' "$out" | python3 -c 'import json,sys
ids=[m["id"] for m in json.load(sys.stdin).get("data",[])]
hits=[i for i in ids if any(w in i for w in ("sonnet","haiku","opus"))]
print("  models on this account:", ", ".join(hits[:8]) or ", ".join(ids[:8]))' 2>/dev/null || true ;;
    401) die "HTTP 401 — the key is wrong or revoked. Nothing stored." ;;
    000) die "no answer from api.anthropic.com — WSL has no network right now? (curl -I https://api.anthropic.com)" ;;
    *)   warn "HTTP $code from /v1/models — continuing, the message test below is decisive" ;;
  esac
  out=$(curl -sS -m 30 -w '\n%{http_code}' https://api.anthropic.com/v1/messages \
        -H "x-api-key: $key" -H "anthropic-version: 2023-06-01" -H "content-type: application/json" \
        -d "{\"model\":\"$model\",\"max_tokens\":5,\"messages\":[{\"role\":\"user\",\"content\":\"Say ok.\"}]}" 2>/dev/null || true)
  code="${out##*$'\n'}"; out="${out%$'\n'*}"
  case "$code" in
    200) ok "model '$model' answered a 5-token test message" ;;
    404) die "model '$model' not found for this key. Pick one from the list above and re-run with:  AI_MODEL=<id> $0" ;;
    400) die "HTTP 400: $(printf '%s' "$out" | head -c 200)" ;;
    429|529) warn "HTTP $code (rate limit / overloaded) — key is fine, try again in a minute" ;;
    *)   die "HTTP $code: $(printf '%s' "$out" | head -c 200)" ;;
  esac
}

case "${1:-}" in
  --check)
    step "Secret"
    if k get secret "$SECRET" -n "$PAYMENTS_NS" >/dev/null 2>&1; then
      KEYS=$(k get secret "$SECRET" -n "$PAYMENTS_NS" -o jsonpath='{.data}' | python3 -c 'import json,sys; print(", ".join(json.load(sys.stdin).keys()))')
      ok "secret $SECRET exists with: $KEYS"
      if [[ "$KEYS" == *ANTHROPIC_API_KEY* ]]; then
        KEY=$(k get secret "$SECRET" -n "$PAYMENTS_NS" -o jsonpath='{.data.ANTHROPIC_API_KEY}' | base64 -d)
        verify_key "$KEY" "${AI_MODEL:-$MODEL_DEFAULT}"
      fi
    else
      warn "no secret $SECRET in $PAYMENTS_NS — the bot runs without drafts"
    fi
    step "What the bot sees"
    python3 "$LAB_ROOT/tools/inc.py" ai 2>/dev/null || warn "bot not reachable"
    ;;
  --remove)
    step "Removing the secret"
    k delete secret "$SECRET" -n "$PAYMENTS_NS" --ignore-not-found
    restart_bot
    python3 "$LAB_ROOT/tools/inc.py" ai
    ok "the bot is up with no provider. Incidents still record; drafts say why they are missing."
    ;;
  --ollama)
    URL="${2:-}"; [[ -n "$URL" ]] || die "usage: $0 --ollama http://host.docker.internal:11434"
    step "Pointing the bot at Ollama: $URL"
    k create secret generic "$SECRET" -n "$PAYMENTS_NS" --from-literal=AI_BASE_URL="$URL" \
      --from-literal=AI_MODEL="${AI_MODEL:-llama3.2}" --dry-run=client -o yaml | k apply -f - >/dev/null
    restart_bot
    python3 "$LAB_ROOT/tools/inc.py" ai
    dim "If drafts say 'URLError', the pod cannot reach that address. From inside kind,"
    dim "host.docker.internal usually resolves on Docker Desktop; if not, use your Windows"
    dim "host's LAN IP and make Ollama listen on 0.0.0.0 (OLLAMA_HOST=0.0.0.0)."
    ;;
  "")
    step "Anthropic API key"
    say "  Get one at https://console.anthropic.com -> API keys. A few dollars of credit covers"
    say "  the series; a draft costs a fraction of a cent. It will not be echoed."
    read -rsp "  ANTHROPIC_API_KEY: " KEY; echo
    [[ "$KEY" == sk-ant-* ]] || die "that does not look like an Anthropic key (expected sk-ant-...). Nothing stored."
    MODEL="${AI_MODEL:-$MODEL_DEFAULT}"
    verify_key "$KEY" "$MODEL"
    step "Storing as secret/$SECRET in namespace $PAYMENTS_NS"
    k create secret generic "$SECRET" -n "$PAYMENTS_NS" --from-literal=ANTHROPIC_API_KEY="$KEY" \
      --from-literal=AI_MODEL="$MODEL" --dry-run=client -o yaml | k apply -f - >/dev/null
    unset KEY
    ok "stored (kubectl get secret $SECRET -n $PAYMENTS_NS — values are base64, not encrypted: lab-grade)"
    restart_bot
    step "What the bot sees"
    python3 "$LAB_ROOT/tools/inc.py" ai
    ok "Next: ./scripts/91-ai-smoke.sh"
    ;;
  *) die "usage: $0 [--check | --remove | --ollama URL]" ;;
esac
