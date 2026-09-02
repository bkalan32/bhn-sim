# Day 1 — Building a Local Incident Response Lab on **Windows + WSL2**

Adapted from `day1incidentresponselab.pdf` (written for macOS) for `desktop-6jd2jrp`.
Every substitution is justified in **[CORRECTIONS-DAY1.md](CORRECTIONS-DAY1.md)** — read that
if you want to know *why* something differs from the PDF.

Verified against upstream docs on **1 September 2026**.

---

## The one architectural decision

You are running the lab in **WSL2 Ubuntu**, not in PowerShell.

That is the choice that makes Days 2–20 work. The series is written in bash, and every later
day assumes bash: heredocs, single-quoted jsonpath, `base64 -d`, `curl` with real flags,
`|` into `grep`. Translating all of that to PowerShell twenty times is a tax you pay daily.
Translating the environment once, today, is a tax you pay once.

The split to keep in your head:

```
WINDOWS                          WSL2 UBUNTU
-------                          -----------
Docker Desktop  (the engine)     docker CLI  ->  talks to Docker Desktop
Cursor          (the editor)     kubectl, kind, helm, terraform, python, git
Your browser    (Grafana etc)    every command in this series
```

Docker Desktop and Cursor are **Windows applications**. Installing them inside Ubuntu is the
single most common way people wreck this setup.

---

## Prerequisites

- Windows 11, or Windows 10 build 19041+
- **Hardware virtualization enabled in BIOS/UEFI** — the most common blocker, needs a reboot
- 16 GB RAM (8 GB is genuinely not enough once the monitoring stack is up)
- **40 GB** free disk, not 20 — WSL2's virtual disk grows and never shrinks on its own
- A GitHub account
- Three to four hours, including at least one reboot

---

## Step 1 — WSL2 and the Windows-side installs

There is no Homebrew on Windows. `winget` replaces it for the two GUI apps.

In **PowerShell as Administrator**:

```powershell
wsl --install -d Ubuntu-24.04
wsl --set-default-version 2
```

Reboot. Then set your Ubuntu username and password when the distro first opens.

Back in PowerShell, run the helper in this repo — it writes `.wslconfig` and installs
Docker Desktop, Cursor and Git for Windows:

```powershell
cd $env:USERPROFILE\Downloads\bhn-sim
powershell -ExecutionPolicy Bypass -File .\windows-setup.ps1
```

**Why `.wslconfig` matters:** the PDF says "Docker Desktop > Settings > Resources, give it
8 GB." On the WSL2 backend **that slider does not exist** — Docker gets whatever WSL2 gets.
`C:\Users\<you>\.wslconfig` is the real control.

Then the one manual step that has no macOS equivalent:

> **Docker Desktop → Settings → Resources → WSL Integration → toggle ON your Ubuntu distro
> → Apply & Restart.**

Skip it and `docker ps` inside Ubuntu fails with *"Cannot connect to the Docker daemon"*
while Docker is visibly running in your system tray.

---

## Step 2 — Get the lab into Ubuntu

Open Ubuntu. Copy the lab in from the Windows side, once:

```bash
cp -r /mnt/c/Users/bkala/Downloads/bhn-sim ~/bhn-sim
cd ~/bhn-sim && chmod +x scripts/*.sh
```

Work from `~/bhn-sim` **inside Ubuntu** from now on, not from `/mnt/c/...`. Files on the
Windows drive are reachable but noticeably slower and they pick up CRLF line endings, which
break shell scripts in ways that look like mysterious `\r: command not found` errors.

To edit them: open Cursor, install the **WSL extension**, then `Remote-WSL: Open Folder in WSL`.

---

## Step 3 — Preflight

```bash
./scripts/00-preflight.sh
```

Read-only. It checks memory, CPU, disk, the Docker socket, outbound HTTPS, and the three
ports the lab wants (3000, 8080, 8081), and tells you exactly what to fix if something is short.

---

## Step 4 — Install the command-line tools

The PDF's one-liner (`brew install kubectl kind helm terraform python@3.12 git`) becomes six
upstream sources on Ubuntu. The script handles all of them and is safe to re-run:

```bash
./scripts/01-install-tools.sh
```

| Tool | What it is | Where it shows up in the job |
|---|---|---|
| kubectl | how you talk to Kubernetes | during incidents: pods, logs, restarts |
| kind | a Kubernetes cluster inside Docker | your fake production |
| Helm | an installer for Kubernetes apps | one command instead of 40 config files |
| Terraform | infrastructure as code | later, when the lab moves to AWS |
| Python | scripting | automation, fake services, AI tooling |
| Git | version control | runbooks, code, configs |

**On the Python pin:** the PDF specifies `python@3.12` because Homebrew would otherwise hand
you 3.13+. Ubuntu 24.04 ships 3.12 as its system Python, so the pin is free — no PPA needed.
The script detects a 22.04 distro (which ships 3.10) and adds deadsnakes only then.

Checkpoint the result:

```bash
./scripts/02-verify.sh
```

Writes `checkpoints/day1-versions.txt`. This is your first checkpoint — the PDF is right that
you should keep it.

---

## Step 5 — Create the cluster

```bash
./scripts/03-cluster-up.sh
```

**Read this or lose twenty minutes on Day 3:** kind prefixes every context with `kind-`.
Your context is **`kind-bhn-sim`**, not `bhn-sim`. The PDF never mentions it, and later days
that say `kubectl config use-context bhn-sim` will fail.

```bash
kubectl config current-context     # -> kind-bhn-sim
```

From this point on, this cluster is **production**. Every service you build and every outage
you simulate happens here.

---

## Step 6 — Smoke test

```bash
./scripts/04-smoke-test.sh
```

Deploys nginx, port-forwards it, curls it, deletes it — and cleans up even if you Ctrl-C.

This is the same habit an on-call engineer uses at the start of an incident: **confirm the
platform itself is healthy before blaming an application.** That is the entire point of the
step; the nginx is incidental.

---

## Step 7 — Install the monitoring stack

```bash
./scripts/05-install-monitoring.sh
```

One Helm command installs three tools you will use daily:

- **Prometheus** collects metrics: request rates, error rates, CPU, memory
- **Grafana** turns those metrics into dashboards
- **Alertmanager** fires alerts when metrics cross a threshold

Two things the PDF gets wrong here, both fixed in the script:

1. **"All pods should reach Running" is not true.** Two admission-webhook pods
   (`kps-kube-prometheus-admission-create-*` and `-patch-*`) finish and stay **`Completed`**.
   That is a Kubernetes Job doing its job. Correct expectation: everything is `Running` **or**
   `Completed`, and nothing is `Pending` / `CrashLoopBackOff` / `Error`.
2. **"Wait a few minutes" is not a check.** The script blocks on an explicit `kubectl wait`
   and only then prints the pod table, so you never see a half-installed cluster and think
   it broke.

Also: the PDF line-wraps `--create-namespace` as `--create-` + `namespace`. Copy-pasting that
from the PDF gives you a Helm error. It is one token.

The chart moves fast — **88.6.2** as of today. The PDF's advice not to pin an old version
from a tutorial is correct.

---

## Step 8 — Open Grafana

```bash
./scripts/06-grafana.sh
```

Prints the admin password (with a trailing newline, unlike the PDF's command) and holds the
port-forward open. Then open **http://localhost:3000** in your **Windows** browser — WSL2
forwards localhost into the distro automatically, so it just works.

If it ever stops working after a Windows sleep/resume: `wsl --shutdown` in PowerShell.

**Do not configure anything today.** The goal is to see what a healthy cluster looks like, so
that later you can recognise an unhealthy one. Worth browsing:

- Kubernetes / Compute Resources / Cluster
- Kubernetes / Compute Resources / Namespace (Pods)
- Node Exporter / Nodes

---

## Step 9 — Run Jenkins

```bash
./scripts/07-jenkins.sh
```

Then open **http://localhost:8081**, paste the unlock password it printed, install the
suggested plugins, and create one Freestyle job that runs `echo hello`.

Jenkins runs as a plain container, deliberately not in the cluster — it is lighter on a laptop
and it keeps CI failures from looking like cluster failures.

**Why it matters:** a large share of production incidents are caused by deployments, so
understanding the pipeline is part of incident response. Today it only needs to exist.

---

## Step 10 — Register the hosted tools

Three of these, not five. Two of the PDF's items have changed or should move:

| Tool | Do today | Notes |
|---|---|---|
| **ServiceNow PDI** | **Request it first thing** | Personal Developer Instances are often waitlisted for days. Nothing in Week 1 needs it, but the queue is the long pole. PDIs also hibernate — log in regularly. |
| **New Relic** | Create the account | Free tier is perpetual, no credit card, 100 GB/month ingest, one full platform user. Verified accurate. |
| **Splunk** | Create the account **only** | ⚠️ *Changed from the PDF.* Do **not** download or start Splunk today. |
| **GitHub** | Create private repo `bhn-sim` | |
| **AWS** | ⚠️ **Do not create the account today** | *Changed from the PDF.* |

**Why Splunk moves to Day 3:** the 60-day Enterprise trial clock starts when you first run it,
and the PDF's own (correct) advice is to do all Splunk alerting inside that window, because
the Free licence that follows **cannot run alerts at all**. Free is 500 MB/day. Starting the
clock two days before you use it throws away two days of alerting time.

**Why AWS moves to ~Day 14:** AWS restructured the Free Tier in July 2025. New accounts get a
credit-based plan that expires **6 months after signup**. The lab doesn't touch AWS until
Terraform work around Day 15+. Signing up today burns a sixth of the window on nothing.

---

## Step 11 — Write the runbook

`README.md` in this folder is already scaffolded for you. Fill in the blanks, then:

```bash
cd ~/bhn-sim
git init && git add -A
git commit -m "Day 1: local incident response lab"
git remote add origin git@github.com:<you>/bhn-sim.git
git push -u origin main
```

**The test for a good runbook:** if your laptop died tonight, could you rebuild this
environment from the README in 30 minutes? `scripts/99-teardown.sh` lets you actually prove it
rather than assume it.

---

## Day 1 is done when

```bash
./scripts/08-checkpoint.sh
```

It tests the PDF's exit criteria for real:

- all seven tools answer `--version` and the Docker daemon is reachable
- `kubectl get nodes` shows `Ready` on context `kind-bhn-sim`
- every monitoring pod is `Running` or `Completed`
- Grafana answers on :3000, Jenkins on :8081
- the repo exists and has a remote

---

## Troubleshooting — Windows edition

| Symptom | Cause | Fix |
|---|---|---|
| `Cannot connect to the Docker daemon` in Ubuntu | WSL Integration not enabled | Docker Desktop → Settings → Resources → WSL Integration → toggle your distro |
| Monitoring pods stuck `Pending` | Memory | Raise `memory=` in `C:\Users\<you>\.wslconfig`, then `wsl --shutdown` |
| `$'\r': command not found` | CRLF line endings | You are running from `/mnt/c/...`. Copy to `~/bhn-sim` inside Ubuntu |
| No memory slider in Docker Desktop | Expected on WSL2 | Use `.wslconfig` — this is not a bug |
| `localhost:3000` dead in Windows browser | WSL localhost forwarding stalled | `wsl --shutdown`, reopen; fallback `--address=0.0.0.0` |
| `use-context bhn-sim` → no such context | kind prefixes contexts | It is `kind-bhn-sim` |
| Helm: `unknown flag --create-` | PDF line-wrap artifact | Type `--create-namespace` as one token |
| `curl` behaves oddly | You are in PowerShell | `curl` is aliased to `Invoke-WebRequest`; use `curl.exe`, or better, stay in Ubuntu |
| WSL disk keeps growing | Expected | `wsl --shutdown`, then `diskpart` → `compact vdisk` |
| ServiceNow PDI waitlisted | Common in 2026 | Keep going. Nothing in Week 1 depends on it |

---

## What's next

Day 2 builds the first real service: a fake gift card activation API in Python that exposes
Prometheus metrics, deployed into the cluster, visible in Grafana. From there the lab starts
to look like a business, and the incidents start.

One thing to know before you get there: kube-prometheus-stack only scrapes `ServiceMonitor`
resources carrying the label `release: kps`. Day 2's service will need it, and the symptom of
forgetting is a service that is plainly healthy but invisible in Prometheus.
