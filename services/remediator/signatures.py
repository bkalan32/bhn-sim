"""
Failure signatures — precise conditions, not vibes. docs/remediation-policy.md is the
authority; this file is its executable half. The tier lives with the action.

detect keys:
  alert              the alert name that must be in the firing group
  service            the group's service label must equal this (optional)
  deploy_within_min  a deploy of `service` in the last N minutes must exist — looked up
                     through the incident bot's deploy collector (Grafana annotations),
                     the same source of truth the Day 10 diagnosis uses

What is absent on purpose: the fraud outage. ActivationHighErrorRate with NO recent
deploy matches nothing here and is therefore tier 3 — the remediator writes "human
required" on the ticket and does nothing else. Deciding what not to automate is half
the discipline.
"""

SIGNATURES = [
    {
        "id": "pod-crashloop",
        "tier": 1,
        "action": "delete_pod",
        "detect": {"alert": "PaymentsPodCrashLooping"},
        "rationale": "Deleting a crash-looping pod lets its Deployment replace it; strictly reversible. "
                     "If the replacement crash-loops too, the failure is real and the note says so.",
        "cooldown_s": 600,
        "retry": 0,
    },
    {
        "id": "settlement-crash",
        "tier": 1,
        "action": "rerun_settlement",
        "detect": {"alert": "SettlementJobFailed", "service": "settlement"},
        "rationale": "Re-running settlement is idempotent on this platform (pushadd; last_success only on real success).",
        "cooldown_s": 600,
        "retry": 1,
        "retry_after_s": 180,
    },
    {
        "id": "post-deploy-errors",
        "tier": 2,
        "action": "rollback_activation",
        "detect": {"alert": "ActivationHighErrorRate", "service": "activation", "deploy_within_min": 30},
        "rationale": "Error spike within 30 min of a deploy: rollback is the known fix, but it reverses "
                     "someone's release, so a human confirms.",
        "cooldown_s": 900,
        "retry": 0,
    },
]

ACTIONS = {"delete_pod", "rerun_settlement", "rollback_activation"}


def validate():
    ids = set()
    for s in SIGNATURES:
        assert s["id"] not in ids, f"duplicate signature id {s['id']}"
        ids.add(s["id"])
        assert s["tier"] in (1, 2), f"{s['id']}: tier must be 1 or 2 (tier 3 = no signature)"
        assert s["action"] in ACTIONS, f"{s['id']}: unknown action {s['action']}"
        assert "alert" in s["detect"], f"{s['id']}: detect needs an alert name"
    return True
