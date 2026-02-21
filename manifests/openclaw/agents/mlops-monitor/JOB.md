---
id: mlops-monitor-analysis
schedule: "0 10,16 * * *"
tz: UTC
---

Read the latest MLOps report at /data/reports/mlops-monitor/report.txt.

Analyze for: high error rates (above 5%), latency spikes (above 30s average),
low evaluation scores, or unusual patterns.

If you find anything notable, send a brief summary to
${OPENCLAW_PREFIX}_${SHADOWMAN_CUSTOM_NAME} using sessions_send.
Include specific numbers. If metrics look healthy, no message needed.
