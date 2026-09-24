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

# Day 22 — the UI. Mission Control serves the built React app from UI_DIR (the image's
# /app/ui; absent in tests and on a Day-21 image, where `/` answers JSON as before).
UI_DIR = os.getenv("UI_DIR", os.path.join(os.path.dirname(os.path.abspath(__file__)), "ui", "dist"))

# Addresses the BROWSER uses — not the pod. Grafana panels are iframes and Splunk/Grafana
# Explore are deep links: the browser loads them itself, through the port-forwards that
# scripts/220-mc-open.sh starts (Grafana :3000) and Splunk's published port (:8000).
GRAFANA_PUBLIC_URL = os.getenv("GRAFANA_PUBLIC_URL", "http://localhost:3000").rstrip("/")
SPLUNK_PUBLIC_URL = os.getenv("SPLUNK_PUBLIC_URL", "http://localhost:8000").rstrip("/")
PROM_DATASOURCE_UID = os.getenv("PROM_DATASOURCE_UID", "prometheus")

# The golden-signal panels the Overview embeds (dashboards/*.json; panel ids are pinned in the
# JSON since Day 22 so these URLs cannot drift when someone reorders a dashboard).
EMBED_PANELS = [
    {"dashboard": "bhn-activation", "panel": 5, "title": "Activation — requests by status"},
    {"dashboard": "bhn-activation", "panel": 6, "title": "Activation — error rate %"},
    {"dashboard": "bhn-activation", "panel": 7, "title": "Activation — latency percentiles"},
    {"dashboard": "bhn-egift", "panel": 4, "title": "eGift — orders by status"},
    {"dashboard": "bhn-egift", "panel": 6, "title": "eGift — p95 by step"},
]

# The PromQL behind each number in an incident's metrics snapshot — so the incident page can
# deep-link every number to Grafana Explore. A MIRROR of services/incident-bot/enrich.py QUERIES:
# tests/test_api.py::test_metric_queries_mirror_the_bot reads the bot's source and fails on drift.
METRIC_QUERIES = {
    "activation": {
        "error_rate_pct": '100 * sum(rate(activation_requests_total{status="error"}[5m])) / clamp_min(sum(rate(activation_requests_total[5m])), 0.001)',
        "p95_latency_s": 'histogram_quantile(0.95, sum(rate(activation_latency_seconds_bucket[5m])) by (le))',
        "req_per_s": 'sum(rate(activation_requests_total[5m]))',
        "health_score": 'activation:health_score',
        "error_budget_burn_1h": 'activation:error_budget_burn_rate:1h',
    },
    "egift": {
        "error_rate_pct": '100 * sum(rate(egift_orders_total{status="error"}[5m])) / clamp_min(sum(rate(egift_orders_total[5m])), 0.001)',
        "p95_order_latency_s": 'histogram_quantile(0.95, sum(rate(egift_order_latency_seconds_bucket[5m])) by (le))',
        "p95_activate_step_s": 'histogram_quantile(0.95, sum(rate(egift_step_latency_seconds_bucket{step="activate"}[5m])) by (le))',
        "orders_per_s": 'sum(rate(egift_orders_total[5m]))',
        "health_score": 'egift:health_score',
    },
    "settlement": {
        "minutes_since_success": '(time() - max(settlement_last_success_timestamp)) / 60',
        "last_records": 'max(settlement_records_processed)',
        "last_run_status": 'max(settlement_last_run_status)',
        "health_score": 'settlement:health_score',
    },
}
# The SPL the bot's log collector runs (enrich.top_log_reasons), for the Splunk deep link.
LOG_REASONS_SPL = "index=main app.service={service} app.status=error | stats count by app.reason | sort -count"

# Day 23 — the copilot, server-side. The key comes from secret/ai-keys (scripts/90-ai-secret.sh),
# the same one the bot uses; the MODEL is Mission Control's own choice (CORRECTIONS-DAY23 D2).
ANTHROPIC_API_KEY = os.getenv("ANTHROPIC_API_KEY", "").strip()
ANTHROPIC_URL = os.getenv("ANTHROPIC_URL", "https://api.anthropic.com/v1/messages")
COPILOT_MODEL = os.getenv("COPILOT_MODEL", "claude-opus-5-5").strip()
COPILOT_MAX_TOKENS = int(os.getenv("COPILOT_MAX_TOKENS", "8000"))

# Day 24 — the Game Day console, KPIs, reports, the KB as cards.
GAMEDAY_DIR = os.getenv("GAMEDAY_DIR", "/gameday")            # ConfigMap `gameday` (scripts/240-gameday.sh)
# An EDITOR token for the game-day annotations (the Viewer token above cannot write). Minted by
# scripts/241-mc-grafana-writer.sh into secret/mission-control-config. Missing = no markers, nothing else.
GRAFANA_WRITE_TOKEN = os.getenv("GRAFANA_WRITE_TOKEN", "").strip()
# Where a KB card's "learned from INC-00xx" links go: the incident write-ups live in git, not in the bot.
REPO_URL = os.getenv("REPO_URL", "https://github.com/bkalan32/bhn-sim/blob/main").rstrip("/")
KPI_CACHE_S = float(os.getenv("KPI_CACHE_S", "60"))
