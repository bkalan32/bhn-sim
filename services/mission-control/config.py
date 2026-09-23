"""
config.py — every address and credential Mission Control uses, from the environment.

In-cluster Service DNS for everything that runs in the cluster; container IPs for the two things
that do not (Jenkins, Splunk — kind's CoreDNS cannot resolve Docker container names, which is
why the bot's enrich-config has carried Splunk's IP since Day 10). scripts/210-mc-config.sh
renders the IPs into secret/mission-control-config, and up.sh warns when they drift.
"""

import os


def _b(name, default="false"):
    return os.getenv(name, default).strip().lower() in ("1", "true", "yes")


VERSION = os.getenv("APP_VERSION", "0.1")
NAMESPACE = os.getenv("NAMESPACE", "payments")
DATA_DIR = os.getenv("DATA_DIR", "/data")

# Auth (Step 4): one bearer token, from secret/mission-control-auth. Empty = refuse everything
# under /api/ — auth is on by default, and a missing Secret must fail closed, not open.
MC_TOKEN = os.getenv("MC_TOKEN", "").strip()

BOT_URL = os.getenv("BOT_URL", "http://incident-bot.payments:8020").rstrip("/")
REM_URL = os.getenv("REM_URL", "http://remediator.payments:8030").rstrip("/")
PROM_URL = os.getenv("PROM_URL", "http://kps-kube-prometheus-stack-prometheus.monitoring:9090").rstrip("/")
AM_URL = os.getenv("AM_URL", "http://kps-kube-prometheus-stack-alertmanager.monitoring:9093").rstrip("/")
GRAFANA_URL = os.getenv("GRAFANA_URL", "http://kps-grafana.monitoring").rstrip("/")
GRAFANA_TOKEN = os.getenv("GRAFANA_TOKEN", "").strip()          # Viewer, from secret/enrich-config (Day 10)
JENKINS_URL = os.getenv("JENKINS_URL", "").rstrip("/")         # http://<jenkins container IP>:8080
JENKINS_USER = os.getenv("JENKINS_USER", "").strip()
JENKINS_TOKEN = os.getenv("JENKINS_TOKEN", "").strip()         # a Jenkins API token, not the password

KUBECTL = os.getenv("KUBECTL", "kubectl")
DRY_RUN = _b("DRY_RUN")                    # every action reports what it WOULD do (tests; a safe first deploy)
HEALTH_POLL_S = float(os.getenv("HEALTH_POLL_S", "15"))
UPSTREAM_TIMEOUT_S = float(os.getenv("UPSTREAM_TIMEOUT_S", "1.5"))   # the Overview promise: < 2 s
