# Day 6 — CI/CD, the Bad Deploy, and the Rollback

Adapted from `day6cicdbaddeployrollback.pdf`. Changes in **[CORRECTIONS-DAY6.md](CORRECTIONS-DAY6.md)**.

> The PDF's own troubleshooting section admits its Grafana annotation and its rollback
> trigger don't work as printed. Both are fixed in the main `Jenkinsfile` here. There's also
> a `git` ownership error that makes the very first run red before it does anything.

---

## Why today

Every deploy so far has been you typing `docker build`, `kind load` and `set image`. That
is also how most production incidents start: post-mortems consistently put *"a change we
made"* as the top cause of outages, and the deploy is the change.

The first three questions on almost every bridge: **What changed? When? Can we undo it?**
A good pipeline answers all three automatically. Today you build that, make it ship a bad
release, and watch it catch and reverse the release without you.

---

## Step 1 — Rebuild Jenkins with tools

```bash
./scripts/50-jenkins-rebuild.sh
```

New image with docker, kubectl and kind; on the kind network; your repo mounted at
`/repo`; an *internal* kubeconfig. Your Day 1 jobs and plugins survive — same volume.

⚠️ **Lab shortcut, labelled:** root + Docker socket = root on the host. In a real company
the build agent is a separate pod with scoped credentials. It's in the README so nobody
copies it.

The script proves `kubectl`, `docker` **and `git`** all work inside the container. That third
one is the ownership fix — without it the first build dies at checkout.

## Step 2 — Tests

```bash
./scripts/51-test-local.sh
```

3 pass, 3 skipped. The skipped ones matter later. Note the amount in `test_activate_ok`:
**$25**.

## Step 3 — Read the Jenkinsfile

Five stages, five things a pipeline owes an on-call engineer. Read `Jenkinsfile` top to
bottom — it's 160 lines and every FIX: comment is a real production failure mode.

## Step 4 — Create the job

Either:

```bash
./scripts/52-jenkins-job.sh       # asks for your Jenkins admin password
```

Or in the UI: **http://localhost:8081 → New Item → `deploy-service` → Pipeline → OK →
Definition: Pipeline script from SCM → Git → Repository URL `/repo` → Branch `*/main` →
Script Path `Jenkinsfile` → Save.**

Commit first — the pipeline clones **what's committed**:

```bash
git add -A && git commit -m "Day 6: Jenkinsfile, tests, CI image" && git push
```

## Step 5 — A good deploy

**Build with Parameters** → `SERVICE=activation`, `CHANGE_CAUSE=add unit tests` → Build.
(First run may show plain "Build" — run it once, then the parameters appear.)

Watch the stage view: Test, Build, Deploy, Verify — green, ~4 minutes. Then the evidence:

```bash
kubectl -n payments rollout history deployment/activation
kubectl -n payments get deploy activation -o jsonpath='{.spec.template.spec.containers[0].image}'; echo
```

A revision with your change cause; image `activation:<build number>`. Open the Activation
dashboard: a **blue vertical line** marks the deploy. Hover it — it says why.

## Step 6 — The bad deploy

```bash
./scripts/53-bad-deploy.sh apply
```

Inserts a "velocity check" that rejects cards ≥ $50, **runs the tests — they pass** (the
test uses $25), commits. Then: **Build with Parameters** → `CHANGE_CAUSE=add velocity check
for fraud team`.

Have Grafana, Alertmanager and the Jenkins stage view all visible. Watch:

1. Test **green**. Build **green**. Deploy **green** — pods healthy, `/healthz` fine, rollout completes.
2. Verify sleeps 2 minutes while the load generator sends its 25/50/100 mix — two-thirds now rejected.
3. Verify **red**: "Error rate 66.9% exceeds limit."
4. `post` runs `rollout undo`. Log says **ROLLED BACK**. A **red line** lands on the dashboards.

Now look at what an on-call engineer would have seen with no pipeline safety — Grafana
spiking exactly at the blue line, both alerts firing, Splunk saying `velocity_check_blocked`,
`rollout history` showing revision N with the cause and N+1 as the auto-rollback.

→ `incidents/INC-0006.md`

## Step 7 — Manual rollback drill

The pipeline won't always be there. Re-run the bad build, and **before Verify finishes**:

```bash
./scripts/54-manual-rollback.sh
```

Shows history, asks which revision, rolls back, and **times it** from undo to "error rate
under 5%". Write the number in INC-0006. Day 12 automates it; you'll compare.

## Step 8 — Fix it properly

```bash
./scripts/53-bad-deploy.sh revert
```

Then deploy clean: **Build with Parameters** → `CHANGE_CAUSE=revert velocity check (INC-0006)`.

Then the follow-up the PDF describes and doesn't ship — turn on the production-amounts
test and re-apply the bad code to prove it's caught at *Test* now:

```bash
TEST_PRODUCTION_AMOUNTS=true ./scripts/51-test-local.sh     # green on clean code
python3 ci/velocity_check.py apply
TEST_PRODUCTION_AMOUNTS=true ./scripts/51-test-local.sh     # 2 FAILED — $50 and $100
python3 ci/velocity_check.py remove
```

To make the pipeline enforce it, add `TEST_PRODUCTION_AMOUNTS=true` before `pytest` in the
Test stage.

## Wrap

```bash
git add -A && git commit -m "Day 6: bad deploy, auto-rollback, INC-0006" && git push
./scripts/58-checkpoint-day6.sh
```

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| First build red at Checkout: "dubious ownership" | root vs your uid | `50-jenkins-rebuild.sh` sets `safe.directory` |
| `kind load` fails in Jenkins | not on kind network / no socket | check `docker inspect jenkins` |
| kubectl "connection refused" in Jenkins | normal kubeconfig, not `--internal` | script exports the internal one |
| Build: `requirements.lock.txt not found` | lock is generated, not committed | Test stage freezes it |
| No blue line on dashboards | annotation query missing | re-import the dashboards from this zip |
| Grafana annotation 401 | password fetched in a pod with no kubectl | fixed in Jenkinsfile |
| Rollback didn't trigger | `STAGE_NAME` in post | flag-based; fixed |
| Verify NPE on empty result | regex on "no data" | JSON parse; nodata → rollback |

## What's next

Day 7 is consolidation: a platform health score, one overview dashboard, tidy-ups from the
first week's follow-ups, and a review of six incidents to find what's worth engineering away.
