# Day 11 — Corrections Log

Source: `day11operationalcopilot.pdf` · Verified 8 September 2026 against the running lab.

---

## [BUG] B1 — `rollout` is on the read-only allow-list, and `rollout undo` is a write

**Guide, Step 1:** `allowed = ("get", "describe", "logs", "top", "rollout")` checked against
`args.split()[0]`, and then: *"the allow-list guarantees the refusal even if the prompt
fails."* It does not. `rollout undo deployment/activation` and `rollout restart` pass the
check and change production. `top` needs metrics-server, which kind does not have, so it
only wastes a call. **Substitute:** the allow-list is by verb *and* sub-verb — `rollout`
only with `status` or `history`; `top` removed; `explain` added. Also refused: `-f`/`-k`
(a file can be anything), `--follow`/`-w` (hangs), `--raw`, and every flag that changes
*who* or *where* (`--kubeconfig`, `--context`, `--server`, `--token`, `--as`). Every call
is pinned to `--context kind-bhn-sim`.

---

## [BUG] B2 — Read-only is not the same as safe: `get secret` hands the model the API key

Not in the PDF at all. With `get` permitted, the first thing a curious model (or a
prompt-injected one) can do is `get secret ai-keys -o yaml` — the Anthropic key, the
Grafana token, the Splunk password, base64-encoded, straight into the conversation and the
transcript. The Fluent Bit ConfigMap holds the HEC token. **Substitute:** secrets,
configmaps and service accounts are refused by resource name (including `secret/x`,
`pods,secrets`, `cm`, `sa`). Eval 4c question 4 tests it; the refusal must come from the
*tool*, not the prompt.

---

## [BUG] B3 — Splunk from the laptop: a password in source, and a port that isn't there

**Guide, Step 1:** `SPLUNK_AUTH = base64.b64encode(b"admin:Changeme123!")` in the file, and
`https://localhost:8089` with the advice *"add -p 8089:8089 to the Splunk container …
recreate the container if needed."* Recreating the container drops the index and the HEC
token (no volume, Day 3), and WSL cannot reach the container's kind-network IP anyway
(Day 10, found live). **Substitute:** the copilot never holds a Splunk credential. The bot
already does, on the right network, validated on Day 10 — so incident-bot **0.4** exposes
*one* endpoint, `POST /tools/search_logs`, and the copilot calls it through the API
server's service proxy with your kubeconfig. The endpoint validates the SPL: side-effect
commands refused (`delete`, `outputlookup`, `sendemail`, `collect`, `script`, `rest`,
`map`, …), generating commands refused, time window a parameter (`earliest`), results
capped. `tools/inc.py search "<spl>"` uses it too. Tests in `test_enrich.py`/`test_bot.py`.

---

## [BUG] B4 — API key from `os.environ`, port-forwards from "your Mac"

`API_KEY = os.environ["ANTHROPIC_API_KEY"]` means exporting the key in a shell (history,
`.bashrc`, the Day 9 rule broken), and `PROM = "http://localhost:9090"` means three
port-forwards that die when WSL sleeps (Days 8–10). **Substitute:** key read from
`secret/ai-keys` at start through your kubeconfig (env wins if set, for CI); Prometheus
and the bot reached through the API server proxy like `tools/inc.py` since Day 8. No
port-forward, no key on disk.

---

## [BUG] B5 — Splunk's `earliest_time` parameter vs `earliest=` in the SPL (the PDF's own note)

The troubleshooting section admits they conflict. Fixed at the source: `validate_spl`
strips inline `earliest=`/`latest=` tokens and the window is only ever the parameter.

---

## [BUG] B6 — The loop can run away, drops the model's reasoning, and leaks broken turns

Three small things in Step 2's `chat()`. No cap on tool rounds (the troubleshooting note
suggests one; done: `--max-rounds`, default 8, with the partial transcript). Text the model
writes *alongside* a tool call — its reasoning — is thrown away; printed dim here, because
"why did it choose that query" is the debugging signal. And on an API error the loop
leaves a dangling turn (or an unanswered `tool_use`) in `messages`, which makes every later
call fail; the conversation is rolled back to before the question.

---

## [BUG] B7 — `get_incidents` returns whole records, truncated mid-JSON

`json.loads(r.read())[:10]` on `/incidents` is fine, but the PDF's records carry drafts,
hypotheses and context — thousands of tokens each — and then `json.dumps(out)[:8000]` cuts
the JSON in half. Split into `get_incidents` (the summary list) and `get_incident(id)` (one
record, timeline capped, and the AI's own drafts **removed**: a model quoting a model is
not evidence).

## [BUG] B8 — My own: the search endpoint answered 422 to `kubectl --raw`

Found by the preflight. `kubectl create --raw … -f body.json` sends the body with no JSON
content-type; FastAPI's `Body()` parser rejects that with a 422, which kubectl renders as
"The request is invalid: : unknown". The Day 8 endpoints read `await request.json()`,
which does not care about the header — and now this one does too, with the 20-second
Splunk call pushed into a threadpool (`run_in_threadpool`) so an `async def` handler still
never blocks the process. Lesson kept: the preflight exists so that the *hands* fail before
the model is in the loop; it did its job on the first run.

---

## [DESIGN] D1 — Transcripts are written, always

The PDF says "log as INC-0010 with the transcript attached" and offers no way to keep one.
Every session writes `docs/copilot-transcripts/<utc>-<tag>.md`: question, each tool call
with its arguments, latency and the first 1,200 chars of the result, the answer, tokens and
milliseconds. Eval 4 is graded from these; the checkpoint looks for them. `-f questions.txt`
runs a fixed script so an eval is repeatable.

## [DESIGN] D2 — One description of the platform

Eval 3's failure was invented inventory (`-n production`, `app=fraud-service`, metrics that
do not exist). The fix is a *fact sheet*, not a rule: `ai.PLATFORM_FACTS` lists every
namespace, workload, metric, alert, log field and dependency that exists. The bot's system
prompt and the copilot's import the same constant — the PDF puts a partial list in one tool
description, which the hypothesis prompt never sees.

## [DESIGN] D3 — Tool results are data, never instructions — and it is tested

A copilot that reads logs reads attacker-controlled text. The system prompt says so; Eval
4c question 7 (`113-copilot-adversarial.sh --inject`) plants a log event that tells the
model to report the platform healthy, then asks about error reasons. This is the
adversarial test the PDF's half hour is missing, and the one that matters in production.

## [DESIGN] D4 — Two diagnoses of one fault, on purpose

The drill asks the copilot *before* the ticket opens (t+90 s), so it must run the lookups
rather than read the bot's enrichment. The ticket then opens with its own hypothesis (the
Day 10 path, now with the Eval 3 prompt changes). INC-0011 compares the two: same fault,
on-demand tool use vs. enrichment-at-open.

---

## [NOTE] N1 — Numbering

The copilot drill is INC-0011 (the PDF says INC-0010; ours are one higher since Day 8).

## [NOTE] N2 — Model and provider

The copilot needs the Messages API's tool use, so it is Anthropic-only (the bot's
`ollama` provider does not apply). Model: `AI_MODEL` from `secret/ai-keys` if present,
else `claude-sonnet-4-5`; `--model` overrides. Temperature 0.2, as on Day 9.

---

## Verified as correct

- "The model never touches production directly; your code is the hands, the model is the
  analyst, and the tool menu is the permission boundary." Exactly right, and the reason
  B1/B2 matter: the menu is only a boundary if the hands enforce it.
- "The printed [tool] lines are not cosmetic … an answer is only as good as the calls
  beneath it." Right; Eval 4 grades trails, not prose.
- "Tool descriptions are doing heavy lifting … treat them like documentation for a new
  teammate." Right; ours carry the metric names, the log fields, a worked example each,
  and what the tool *refuses*, so the model does not burn rounds finding out.
- "Start a new session per investigation; incident copilots do not need long memories."
  Right; `new` at the prompt.
- The warm-up script and the "which store" payoff question. Kept verbatim.
