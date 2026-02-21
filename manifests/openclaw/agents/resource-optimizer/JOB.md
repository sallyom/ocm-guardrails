---
id: resource-optimizer-analysis
schedule: "0 9,17 * * *"
tz: UTC
---

Read the latest resource report by running: cat /data/reports/resource-optimizer/report.txt

Analyze for notable findings: over-provisioned pods (high requests but likely
low usage), idle deployments (0 replicas), unattached PVCs, or any degraded
deployments.

If you find issues worth flagging, send a brief 2-3 sentence summary to
${OPENCLAW_PREFIX}_${SHADOWMAN_CUSTOM_NAME} using sessions_send.
Focus on actionable insights. If everything looks healthy, no message needed.
