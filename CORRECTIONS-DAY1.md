# Day 1 — Corrections Log

Source: `day1incidentresponselab.pdf`
Target machine: `desktop-6jd2jrp` — **Windows x64**, running the lab inside **WSL2 Ubuntu**
Verified against upstream docs on 1 September 2026.

Two kinds of entries below: **[PLATFORM]** = the guide is macOS-only and had to be
translated. **[BUG]** = the guide is wrong, inconsistent, or will bite you regardless
of operating system.

---

## [PLATFORM] P1 — Homebrew does not exist on Windows

**Guide, Step 1:** "Go to https://brew.sh and paste the install command into Terminal."

Every install in Steps 2, 3 and 10 is a `brew` command, so Step 1 failing takes the whole
day with it. There is no Homebrew for Windows.

**Substitute:** two package managers, split by where the software actually runs.

| Layer | Manager | Installs |
|---|---|---|
| Windows host | `winget` (built into Windows 11 / recent Win10) | Docker Desktop, Cursor, Git for Windows |
| WSL2 Ubuntu | `apt` + upstream vendor repos | kubectl, kind, helm, terraform, python, git |

You already have a `.chocolatey` folder in your home directory, so Chocolatey works too —
but `winget` ships with the OS and needs no admin bootstrap, so the scripts use it.

**Why the split matters:** Docker Desktop and Cursor are Windows GUI applications. Installing
them inside Ubuntu is the single most common way people wreck this setup. The CLI tools go
in Ubuntu because that is where you will actually be typing.

---

## [PLATFORM] P2 — Docker memory is not set in Docker Desktop's Settings on WSL2

**Guide, Step 2:** "Open Docker Desktop, then go to Settings > Resources and give it at
least 8 GB of memory."

On macOS Docker runs in its own VM and that slider exists. On Windows with the WSL2 backend
**there is no memory slider** — Docker inherits whatever WSL2 itself is allowed to use.
Following the guide literally, you will look for a control that is not on the screen, assume
you did something wrong, and start over.

**Substitute:** create `C:\Users\<you>\.wslconfig` (Windows side, not Ubuntu):

```ini
[wsl2]
memory=10GB
processors=4
swap=2GB
```

Then `wsl --shutdown` from PowerShell and reopen Ubuntu. This is the equivalent control.
10 GB rather than 8 because Windows itself needs headroom that macOS did not.

---

## [PLATFORM] P3 — `brew install --cask docker`

**Substitute:** `winget install -e --id Docker.DockerDesktop` in **PowerShell**, then in
Docker Desktop → Settings → Resources → **WSL Integration**, toggle on your Ubuntu distro.
That toggle is the step with no macOS equivalent, and without it `docker ps` inside Ubuntu
returns "Cannot connect to the Docker daemon" even though Docker is plainly running.

---

## [PLATFORM] P4 — `brew install kubectl kind helm terraform python@3.12 git`

One line on macOS, six different upstream sources on Ubuntu. `scripts/01-install-tools.sh`
does all of them; versions pinned to what I verified today:

| Tool | Source | Version verified 2026-09-01 |
|---|---|---|
| kubectl | `pkgs.k8s.io` apt repo (v1.34) | tracks stable |
| kind | binary from `kind.sigs.k8s.io/dl/` | **v0.33.0** |
| helm | `get.helm.sh` install script | tracks stable |
| terraform | HashiCorp apt repo | tracks stable |
| python3.12 | **already in Ubuntu 24.04** | 3.12.x |
| git | apt | 2.4x |

**Note on Python:** the guide is careful to specify `python@3.12` because Homebrew would
otherwise give you 3.13+. Ubuntu 24.04 ships 3.12 as its system Python, so this pin costs
you nothing and needs no `deadsnakes` PPA. If your WSL distro is Ubuntu 22.04 it ships 3.10
and you *would* need the PPA — the install script detects this and tells you.

---

## [PLATFORM] P5 — `base64 -d` and `curl`

**Guide, Steps 5 and 7:** `curl localhost:8080` and `... | base64 -d`.

Both are fine **inside Ubuntu** and both break **in PowerShell**:

- PowerShell aliases `curl` to `Invoke-WebRequest`, which does not accept curl's flags. Use
  `curl.exe` if you are in PowerShell.
- `base64` does not exist in PowerShell. The Grafana password decode there is
  `[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))`.

The rule for the rest of the series: **run every lab command in Ubuntu, not PowerShell.**
That is the whole reason we chose WSL2 — it keeps Days 2–20 copy-pasteable as written.

---

## [PLATFORM] P6 — `brew install --cask cursor`

**Substitute:** `winget install -e --id Anysphere.Cursor` in PowerShell. Then install the
**WSL extension** inside Cursor and open your lab with `Remote-WSL: Open Folder in WSL`.
Editing WSL files through the Windows path (`\\wsl.localhost\...`) works but is slow and
mangles line endings; the extension is the correct path.

---

## [PLATFORM] P7 — Prerequisites are understated for Windows

**Guide:** "A Mac with at least 16 GB RAM (8 GB will work, but it will be tight) /
Around 20 GB free disk space / Two to three hours."

For Windows, realistically:

- Windows 11, or Windows 10 build 19041+ (WSL2 requires it)
- Hardware virtualization **enabled in BIOS/UEFI** — this is the #1 blocker and it needs a reboot
- 16 GB RAM. 8 GB is not "tight" here, it is not enough: Windows + WSL2 VM + Docker + a kind
  cluster + the full Prometheus stack does not fit
- **40 GB** free, not 20. kind node images, the monitoring stack, Jenkins and (from Day 3)
  Splunk add up fast, and WSL2's virtual disk grows but never shrinks on its own
- **Three to four hours**, including at least one reboot

---

## [BUG] B1 — The cluster context is not called `bhn-sim`

**Guide, Step 4:** `kind create cluster --name bhn-sim`

kind prefixes every context it creates with `kind-`. Your kubectl context is
**`kind-bhn-sim`**, not `bhn-sim`. The guide never says this, and later days that tell you to
run `kubectl config use-context bhn-sim` will fail with "no context exists with the name".

Confirm with `kubectl config current-context`.

---

## [BUG] B2 — "All pods should reach Running" is not true

**Guide, Step 6:** "All pods should reach Running."

kube-prometheus-stack runs two admission-webhook Jobs at install time. Their pods —
`kps-kube-prometheus-admission-create-*` and `kps-kube-prometheus-admission-patch-*` — finish
their work and land in **`Completed`**, permanently. That is success, not a hung install.

A Day 1 reader who has never seen a Kubernetes Job will spend twenty minutes debugging two
pods that are working exactly as designed. Correct expectation: every pod is either `Running`
**or** `Completed`, and nothing is in `Pending`, `CrashLoopBackOff` or `Error`.

---

## [BUG] B3 — Step 6 has no wait, so its own check looks like a failure

The guide says "Wait a few minutes, then check" but gives you no way to know when. Run
`kubectl get pods -n monitoring` too early — which everyone does — and you see `Pending` and
`ContainerCreating` and conclude it broke.

**Substitute:** `scripts/05-install-monitoring.sh` blocks on an explicit
`kubectl wait --for=condition=Ready pod --all -n monitoring --timeout=600s` and only then
prints the pod table. Deterministic instead of "a few minutes".

---

## [BUG] B4 — The Helm command is split across a line break in the PDF

In the PDF, Step 6 renders as:

```
helm install kps prometheus-community/kube-prometheus-stack -n monitoring --create-
namespace
```

Copy-paste that and you get `--create-` as a flag and `namespace` as a positional argument,
and Helm errors out. It is a PDF line-wrap artifact, not a real flag, but it will cost you a
confused minute. The correct flag is `--create-namespace`, one token.

---

## [BUG] B5 — AWS Free Tier is no longer what the guide describes

**Guide, Step 9:** "AWS free tier: create the account only. Do not use it this week."

AWS restructured the Free Tier in **July 2025**. New accounts now get a credit-based plan
(credits on signup, more as you complete onboarding) that expires **6 months after signup**,
alongside a smaller set of always-free services. The old "12 months of free t2.micro" framing
the guide implies is gone.

**This changes the advice.** The guide has you move the lab to AWS with Terraform somewhere
around Day 15+. If you create the account on Day 1 and then don't touch it, you burn roughly
a fifth of your 6-month window before you use a single service.

**Substitute:** do **not** create the AWS account on Day 1. Create it the day before you
first need it. Nothing in Days 1–14 depends on it.

---

## [BUG] B6 — Step 9 tells you to download Splunk on a day that is supposed to be accounts-only

Step 9 is framed as "create free accounts now," then quietly instructs "Download Splunk
Enterprise (it runs fine in Docker)." That is a multi-GB download and a container that needs
specific env vars, and none of it is used until Day 3.

The 60-day Enterprise trial clock also starts at first run, and the guide's own advice is to
do all Splunk alerting inside that window. Starting the clock two days early is free time
thrown away.

**Substitute:** Day 1 = register the account only. Day 3 = pull the image and start the
trial. Everything the guide says about the licence is otherwise **correct and verified**:
60-day Enterprise trial, then Free at 500 MB/day, and **Free genuinely cannot run alerts**.

---

## [BUG] B7 — Grafana's `admin` password lookup has a portability trap

**Guide, Step 7:** the `jsonpath` is wrapped in double quotes:

```
kubectl get secret kps-grafana -n monitoring -o jsonpath="{.data.admin-password}" | base64 -d
```

Correct in bash. If you ever run it in PowerShell the braces survive but the pipe to `base64`
does not. Single quotes are the safer habit in bash anyway. Minor, but it is the kind of thing
that silently produces an empty password at 3 AM.

Also worth knowing and not stated: the output has **no trailing newline**, so your next shell
prompt appears glued to the password. Append `; echo` to see it cleanly.

---

## [BUG] B8 — Port 3000 and the Windows-vs-WSL localhost question

The guide assumes port-forwarding and browsing happen on the same machine. Under WSL2 they do
not: `kubectl port-forward` runs in Ubuntu, your browser runs in Windows.

**Good news:** WSL2 forwards localhost automatically, so `http://localhost:3000` in your
Windows browser reaches a port-forward started in Ubuntu. It works — but it is worth knowing
*why* it works, because when it stops working (it occasionally does after a Windows sleep),
the fix is `wsl --shutdown` and not an hour of debugging Grafana.

If it does fail, `kubectl port-forward --address=0.0.0.0 ...` is the fallback.

---

## Verified as correct — no change needed

Things I checked that the guide gets right, so you can trust them:

- **kube-prometheus-stack chart is on 88.x.** Latest today is **88.6.2** (app v0.93.1). The
  guide's warning not to pin an old version from a tutorial is good advice.
- **Both Helm install forms work.** The classic `repo add` route and the newer
  `oci://ghcr.io/prometheus-community/charts/kube-prometheus-stack` route install the same chart.
- **Splunk licensing.** 60-day Enterprise trial → Free at 500 MB/day, and alerting is not
  available on Free. Do the alerting work inside the trial window, exactly as the guide says.
- **New Relic free tier.** 100 GB/month ingest, one full platform user, no credit card.
- **The service name `kps-grafana`** is right for a release named `kps`.
- **Jenkins on 8081.** Deliberate and correct — it avoids the collision with Jenkins' own
  internal 8080 and leaves 8080 free for the Step 5 smoke test.
- **The "seven tools" checkpoint** is consistent: six from Step 3 plus Docker from Step 2.
- **Running Jenkins as a plain container rather than in the cluster** is the right call for a
  laptop, and the guide is right to flag it in troubleshooting.
