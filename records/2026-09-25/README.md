# Lab record — exported 2026-09-25, before teardown

Mission Control's SQLite tables (`mc-*.json`) and, through its API, the incident bot's incidents,
KPIs and daily reports. The lab itself is rebuilt from the repo; this is what it remembered.

- audit rows: 157 (74 actions, 83 AI tool calls)
- copilot answers: 33, cost $1.56
- grades: 23 (20 up, 3 down)
- game-day runs: 1

## Actions by entrance and result

| action | entrance | result | n |
|---|---|---|---|
| close_incident | button | failed | 1 |
| close_incident | button | ok | 1 |
| close_incident | button | rejected | 4 |
| generate_report | button | ok | 1 |
| generate_report | command | ok | 1 |
| kb_feeding | button | ok | 2 |
| note | api | ok | 1 |
| note | button | ok | 3 |
| note | copilot | pending | 1 |
| rate_answer | button | ok | 20 |
| rate_draft | button | ok | 2 |
| rate_report | button | ok | 1 |
| rerun_settlement | api | ok | 1 |
| reset_faults | button | ok | 1 |
| run_scenario | button | ok | 1 |
| run_scenario | button | pending | 1 |
| scale | api | declined | 2 |
| scale | api | pending | 2 |
| scenario_step | scenario | ok | 2 |
| set_fault | api | ok | 5 |
| set_fault | api | pending | 9 |
| set_fault | button | declined | 1 |
| set_fault | button | ok | 6 |
| set_fault | button | pending | 1 |
| set_fault | command | pending | 2 |
| set_fault | copilot | pending | 1 |
| set_fault | system | expired | 1 |
