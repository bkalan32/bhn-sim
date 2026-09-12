# Day 19 — Corrections Log

Source: `day19finalgamedayaws.pdf` ("verified on 29 August 2026") · Built 12 September 2026.

---

## [BUG] B1 — The warm start's four commands describe a layout this lab never had

**Guide, Step 1.** `cd infra/aws/env && terraform apply  # vpc, eks, ecr`, then
`aws eks update-kubeconfig … --region ap-southeast-1`, then `cd ../platform && terraform
apply`, then `kubectl apply -f k8s/aws/`. Four things: the region is **us-east-2** (Day 15);
`env` does not contain EKS — three roots, three state keys (Day 16 D1), because the cluster
is destroyed nightly and the network is not; `k8s/aws/` is *rendered* from `k8s/` with the
ECR image tags of the moment (163), not a directory you apply; and the platform apply needs
the CRDs first (162, B11). **Substitute:** `190-eks-warm-start.sh` orders the eight scripts
you already have and times them.

---

## [BUG] B2 — "Recreate the ai-keys and newrelic-license secrets in the new cluster"

**Guide, Step 1.** `ai-keys` has been copied kind → EKS through a pipe by 163 since Day 16
(never a file). `newrelic-license` is **not wanted on EKS**: New Relic is a kind-only
release by design (Day 17 B4 — the remote-write overlay references a Secret that must not
exist on EKS and would leave Prometheus unable to mount). The PDF's "note the real-world
equivalent is a secrets manager" stands; the lab's equivalent is "the secret never becomes a
file" (Day 9's rule).

---

## [BUG] B3 — "KB and copilot read local files and port-forwards from your Mac"

**Guide, Step 1.** Neither is true here. The KB is a **ConfigMap** mounted into the bot (Day
17 D1), so a new cluster has no KB until `172` runs against it — phase 6 of the warm start.
The copilot has never used a port-forward: every hand goes through the API server's service
proxy with `KUBE_CONTEXT` (Day 11), so "point it at EKS" is one environment variable — and
its system prompt now states which cluster it is on, so a stale kind answer during an EKS
game day is impossible to miss (the PDF's "update the copilot's context comment", done as a
runtime line rather than a comment). The only port-forwards in the lab are the load
generators' (164).

---

## [BUG] B4 — "The burn or latency alert opens an incident"

**Guide, Step 3.** Day 18 removed the static latency alert; the only rule fault 1 can trip is
`ActivationLatencyBudgetBurn` (1h and 5m windows > 14.4×). With every request over 300 ms
the 1h window needs **~9 minutes** before it crosses, and the alert is a *warning* — a
ticket, not a page. That is the design being tested, so the scenario says so in its
comment and `192 status` prints the burn rate climbing; a responder who expects a page in
three minutes has misread Day 18, not the platform.

---

## [BUG] B5 — "Log the drill as INC-0020 through INC-0022" — 0020 was taken by a KPI row

Day 18 filed two findings as `0020-a`/`0020-b` in `docs/ops-kpis.md`. Findings hang off the
last incident of their day (Day 14's `0017-a/b/c`); Day 18 had no incident, so they are now
**`0019-a`/`0019-b`** and INC-0020..0022 are today's three tickets, as the PDF says.

---

## [BUG] B6 — Teardown: `cd platform && destroy; cd ../env && destroy` skips the cluster and the log group

**Guide, Step 5.** Between the platform root and the env root sits the EKS root, and outside
Terraform sits `/bhn-sim/containers` (Fluent Bit creates it; Terraform does not know it).
`167 --all` does platform → cluster → log group → env and ends with the every-region sweep
(155). On Day 16 the env step was skipped by hand and billed a night — the checkpoint now
requires the teardown marker to be *newer than the game*.

---

## [DESIGN] D1 — The third collector on EKS: CloudWatch Logs Insights through Pod Identity

INC-0018's follow-up, open for three days: on EKS the bot diagnosed with two sources of
three because Splunk is a container on the laptop. Today `enrich.py` has a second logs
backend. `LOGS_BACKEND` is `splunk` when `SPLUNK_URL` is set, `cloudwatch` when
`CW_LOG_GROUP` is (100 sets it on EKS), `none` otherwise — and the *rows* are identical
(`reason`, `count`), so the hypothesis prompt cannot tell which cloud it is on. The
credential is no credential: the bot's ServiceAccount (new in `k8s/incident-bot.yaml`) is
associated to an IAM role by Pod Identity (`pod-identity.tf`, `payments/incident-bot`)
scoped to read-only Insights on the one log group. boto3 is the image's first third-party
dependency beyond the web stack; it is imported only when the backend is CloudWatch, so kind
never loads it. The copilot's `search_logs` speaks SPL; on EKS the bot translates the
subset the copilot and the collectors actually use (`key=value … | stats count by … | sort
| head | table`) and **refuses the rest with a reason** — the same rule as Day 11: a tool
result that says why lets the model rephrase.

## [DESIGN] D2 — Jittered gaps, sealed log, three knobs counted

`scenario-2.sh` keeps the PDF's three faults and order (the order matters: the settlement
reset is a mid-scenario act) but jitters the gaps (200–290 s) so the wall clock cannot
substitute for the platform, logs only to a dot-file read at the retro, and `192` counts
live faults across all three knobs (`BASE_LATENCY_MS`, `SETTLEMENT_FAIL_MODE`,
`EMAIL_FAIL_RATE`) without naming them until `retro`.

## [DESIGN] D3 — The retro computes the KPI rows

`192 retro` joins the scenario log's injection times to the tickets' `first_alert_at`,
`opened_at`, `resolved_at` and the hypothesis event, and prints TTD / alert→ticket /
hypothesis / TTR / the remediator's last note per incident — the numbers for rows
0020–0022 and the graduation table. The words are yours.

## [NOTE] N1 — The scenario is in the repo, as on Day 14

The PDF says "write it, seal it, walk away". The scenario ships written (so its faults can
be validated against the services' real knobs), with the same rule as Day 14: you do not
read it until the retro. Its comments are the grading rubric.

## [NOTE] N2 — Insights costs money by the byte scanned

$0.005 per GB. The bot's collector scans the last 10 minutes of one namespace's logs per
ticket — kilobytes. The copilot's `search_logs` can ask for `-1d`; the translator passes the
window through, so a careless question scans a day. Megabytes still; noted so the cost row
can say why the CloudWatch line is not zero.

---

## Verified as correct

The three faults and why each is different; "walk away for five minutes"; the settlement
reset as the "vendor fixed it" moment; the honest limit on the latency case (env knob vs
regression) belongs on the timeline; "you are also the scribe"; the graduation questions
and their expected answers (automation quality tracks pattern maturity; machines for the
known, humans for the ambiguous and the external); the papercuts as pre-felt first-week
friction; "the report can only see what the record holds, which is the whole moral of the
series"; keep the bucket, ECR, IAM and the budget — one apply away forever.
