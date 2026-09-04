# Day 6 — Corrections Log

Source: `day6cicdbaddeployrollback.pdf` · Verified 2 September 2026.

The PDF's own troubleshooting section admits two of its pipeline steps are broken as
written (the Grafana annotation and the rollback trigger). Those are fixed in the main
Jenkinsfile here rather than left as footnotes, plus the ones it doesn't mention.

---

## [BUG] B1 — Jenkins runs as root; the repo is owned by you; git refuses

`-u root` with `-v "$(pwd)":/repo`. Every file in `/repo` is owned by your WSL uid. Git ≥
2.35.2 refuses to touch a repository owned by a different user:

```
fatal: detected dubious ownership in repository at '/repo'
```

That kills **both** the pipeline's `git clone /repo` and the job's own SCM checkout, so
the very first run is red before it does anything. Fixed in `ci/Dockerfile.jenkins` with
`git config --system --add safe.directory '*'`.

---

## [BUG] B2 — The Grafana annotation returns 401 (PDF admits it)

The PDF fetches the Grafana password with `$(kubectl get secret …)` *inside* a `kubectl
run` pod running `curlimages/curl`, which has no kubectl. The substitution is empty, the
auth header is `admin:`, Grafana says 401. The PDF's troubleshooting note says to fix it
"in a separate sh step." Done: fetch on the agent, then `kubectl exec` into the Grafana pod
(it has curl) and POST to `localhost:3000`. No helper pod at all.

---

## [BUG] B3 — `env.STAGE_NAME` in `post{}` is unreliable (PDF admits it)

The rollback condition `env.STAGE_NAME == 'Verify'` doesn't hold in `post` on current
Jenkins. The PDF's own note says to set a flag. Done: `env.VERIFY_FAILED = 'true'` before
`error()`, checked in `post { failure }`. A test or build failure now correctly does *not*
roll back — nothing was deployed.

---

## [BUG] B4 — Deploy annotations don't appear on dashboards without an annotation query

"A vertical line appears on every dashboard at deploy time. That line answers 'when?'
forever." Not without configuration. Grafana's built-in annotation query shows only
annotations bound to *that dashboard*. Org-level annotations posted via the API (which is
what the pipeline posts) are invisible unless the dashboard has a query filtering by tag.
All three dashboards now carry `Deploys` (blue, tag `deploy`) and `Rollbacks` (red, tag
`rollback`) annotation queries.

---

## [BUG] B5 — The Verify regex explodes on "no data"

```groovy
def err = (out =~ /"value":\[[^,]+,"([^"]+)"/)[0][1].toFloat()
```

When Prometheus returns an empty result — no traffic after the deploy, which is itself the
worst outcome — the regex matches nothing, `[0]` is a `NullPointerException`, the stage
fails for the wrong reason, and because the flag isn't set, **no rollback**. Replaced with a
JSON parse that returns `nodata`, which Verify treats as a failure *with* rollback.

---

## [BUG] B6 — The Dockerfile COPYs a file that isn't committed

Our Dockerfiles `COPY requirements.lock.txt`, which `build_service` generates and git
ignores. A clean clone inside Jenkins has no lock file, so `docker build` fails. The Test
stage now freezes the lock from the venv it just tested with — the image is built from
exactly the dependencies the tests ran against, which is the right order anyway.

---

## [BUG] B7 — `kubectl set image` again (Day 3 B6, pipeline edition)

The PDF deploys with `set image`, leaving `k8s/activation.yaml` saying something else. The
pipeline now applies the **manifest** with the tag substituted, so probes, env and resources
stay in step with the file. The remaining drift — the tag in git — is what GitOps fixes,
and it's out of scope for Day 6; noted in the README.

---

## [BUG] B8 — The Verify query is activation-only (PDF admits it)

`${SERVICE}_requests_total` doesn't exist for egift. Mapped: `egift_orders_total`.

---

## [BUG] B9 — The test asserts a dict the app doesn't return

`assert client.get("/healthz").json() == {"status": "ok"}` — our `/healthz` also returns
`version`. Asserting `["status"] == "ok"` instead. Also the PDF's test needs `httpx` for
`TestClient`, which is the same hidden-dependency trap that bit you on Day 2 (`httpx2`);
the tests here start the real server and use the standard library.

---

## [BUG] B10 — The bad-release snippet won't run against our code

The PDF's velocity check calls `LATENCY.observe(...)` with no label and uses `time.time()`
against `start = time.perf_counter()`. Against the Day 2 fixes it raises on every request,
giving 100% errors instead of the intended 67% — caught either way, but for the wrong
reason. `ci/velocity_check.py` applies a version that matches the codebase, as an
anchored insert so it survives unrelated edits.

---

## [DESIGN] D1 — Both follow-ups from INC-0006, shipped

The PDF lists two follow-ups and leaves them. Both are implemented:
- **`test_activate_all_production_amounts`** — parametrised over 25/50/100, gated behind
  `TEST_PRODUCTION_AMOUNTS=true` so you can watch the bad release pass first. Verified:
  3 pass without it, 2 fail with it.
- **Verify compares to the pre-deploy baseline** — fails on `max(threshold, 3 × baseline)`.

---

## [PLATFORM] P1 — Reaching Prometheus from Jenkins

The Jenkins container is on the Docker network, not in the cluster, so `kps-…prometheus.
monitoring:9090` doesn't resolve there — hence the PDF's `kubectl run` curl pods. Cleaner:
`kubectl get --raw /api/v1/namespaces/monitoring/services/…/proxy/api/v1/query`, the API
server's service proxy. Works from anywhere kubectl works, no pods, no DNS.

---

## Found live — two more

**[PLATFORM] P2 — Debian 13 split `docker.io`.** The `jenkins:lts` base moved to trixie, where
`docker.io` is now only the daemon; the client is a separate `docker-cli` package. `apt-get
install docker.io` succeeds, the build goes green, and there is no `docker` command. Fixed by
taking the CLI from Docker's static builds, and the build script now verifies every tool
exists in the image before replacing the running container.

**[BUG] B11 — The git plugin refuses local checkouts.** "Repository URL `/repo`" hits a 2022
hardening: `Checkout of Git remote '/repo' aborted because it references a local directory`.
Needs `-Dhudson.plugins.git.GitSCM.ALLOW_LOCAL_CHECKOUT=true` in `JAVA_OPTS`. Lab only.

**[BUG] B12 — `Math.max` is rejected by the Groovy sandbox.** Replaced with a comparison.
Also: the Grafana password was printed in the build log by `sh`'s command echo — now
passed via env with `set +x`.

## Verified as correct

- The five-stage framing and "the three questions on every bridge." Exactly right.
- `kind get kubeconfig --internal` — the fix for "connection refused from inside a container."
- Running as root with the Docker socket as a *labelled* lab shortcut. Correct to flag it.
- `kubernetes.io/change-cause` for rollout history — the cheapest possible "what changed."
- The bad-release scenario: tests green, deploy green, traffic red. That is the real shape.
