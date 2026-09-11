# Interactive Demo Privacy And Data Dictionary

The demonstration collects formative operational and usability evidence, not
research-participant data and not evidence of adoption. The public metric is
`anonymous browser sessions`; it must not be renamed to people, users, or
unique attendees.

| Field group | Examples | Purpose | Visibility | Retention |
| --- | --- | --- | --- | --- |
| Session envelope | HMAC-hashed session ID, organization, issued/expiry time | quotas, funnel, authorization | private operations | 30 days maximum |
| Artifact manifest | SHA-256, byte size, extension, generated name, controlled selections | demonstrate provenance without uploading content | public demo fields | 30 days maximum outside ledger; ledger cleanup follows runtime destroy |
| Workflow manifest | generated ID, one to three artifact IDs, organization | demonstrate linked provenance | public demo fields | runtime only plus sanitized report |
| Funnel events | session created, artifact accepted/confirmed, workflow confirmed, history viewed | formative usability counts | aggregate report | 30 days maximum |
| Reliability | request/confirmation duration, failure/retry, queue depth/age, pod/ALB/Fabric state | operational evidence | private report, aggregate excerpts | 30 days maximum |
| Survey | three ratings, optional escaped comment up to 300 characters | convenience-sample feedback | private; ratings may be aggregated | 30 days maximum |
| Security logs | operational IP address when necessary, WAF action, timestamp | abuse response | restricted operators | 7 days maximum |

Never collect or export file bytes, original filenames, names, email
addresses, demographic data, raw session IDs, cookies, authorization headers,
Fabric private keys, or application secrets. Feedback is never written to the
ledger or displayed publicly. Export must fail when a field is not allowlisted.
WAF logging redacts cookies, authorization, `X-Demo-Control-Key`,
`X-Demo-CSRF`, and `X-Api-Key`. Lifecycle operations call the internal demo
control endpoints through `kubectl exec` and loopback inside the API Gateway
pod, so control credentials are not sent through CloudFront or WAF.
The control-key-protected operational endpoint exposes only totals, confirmation
latency sample size/p50/p95, and queue totals/oldest-pending age. Monitoring
stores only those aggregates plus aggregate pod, ALB, Fabric, RabbitMQ, WAF, and
cost signals; it does not store Kubernetes object names or message payloads.

The S3 lifecycle rules enforce seven-day security-log expiry and 30-day expiry
for sanitized evidence and runtime state. The final report may retain aggregate
numbers and non-identifying conclusions only after the source records expire.
