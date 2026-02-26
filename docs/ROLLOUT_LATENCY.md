# Staged Rollout: Zero-Regression Latency & Stability

Use this checklist when shipping latency/stability changes in phased PRs.

## Phased PRs

- [ ] **Phase 0** (baseline): Request metrics and regression specs are merged first. Enable `REQUEST_METRICS_ENABLED=1` in staging and capture baselines before any optimization.
- [ ] **Phase 1** (quick wins): Single PR for sleep removal and duplicate JS removal. No behavior change; run full spec suite and wallet/settlement contract specs.
- [ ] **Phase 2** (DB): Single PR for composite indexes migration + settlement batch queries. Run migrations on staging first; run `db:test:prepare` and settlement/dashboard specs.
- [ ] **Phase 3** (gift card lookup): PR for `code_lookup_hash` migration + `find_active_by_code` refactor. Run migration and redemption + gift card specs; monitor `[PARITY]` logs for legacy path usage.
- [ ] **Phase 4** (external I/O): PR for webhook `enqueue_notification` (no sync send in production). Verify webhook and notification specs; confirm Sidekiq is healthy in production.
- [ ] **Phase 5** (frontend): PR for wallet JSON endpoint + fetch-based load. Verify wallet HTML and JSON contract specs; spot-check wallet UI.
- [ ] **Phase 6** (runtime): PR for DB pool, Puma comments, Redis cache timeouts, Render env vars. No app logic change; validate deploy and pool size.

## Canary / Monitoring

- Enable **request metrics** in production (or a canary instance) with `REQUEST_METRICS_ENABLED=1` and collect p50/p95/p99 and query counts for:
  - `/gift_cards`, `/gift_cards/success`
  - `/merchant/redemptions`, `/merchant`, `/merchant/settlements`
  - `/api/v1/checkout/payment_intent`, `/webhooks/stripe`
- Compare post-rollout metrics to baseline; confirm latency and DB time improvements without regressions.

## Regression Alerts

- **Checkout**: Monitor success rate and 4xx/5xx on `/api/v1/checkout/payment_intent` and Stripe webhook 2xx.
- **Redemption**: Monitor redemption success rate and any increase in “card not found” or legacy-path logs.
- **Wallet**: Monitor 200 and JSON structure for `GET /gift_cards.json`; ensure no increase in JS errors or empty wallet when data exists.
- **Background**: Monitor Sidekiq queue depth and failed jobs; if Redis is down, webhook must still return 200 and log notification failure (no blocking).

## Rollback Criteria

- **Roll back** if:
  - p95 or p99 latency increases materially on any critical path above.
  - Checkout or redemption success rate drops.
  - Wallet page or JSON contract breaks (specs fail or user reports).
  - DB pool exhaustion or Redis connection errors spike.
- **Rollback steps**: Revert the phase PR; if migrations were run, prefer additive rollbacks (no destructive migrations in rollback). Re-run migrations only if a later phase depends on a new column; otherwise leave DB as-is.

## Definition of Done (per phase)

- Same flows, same outputs, same business behavior.
- Relevant request/model/contract specs pass.
- Staging (and canary, if used) shows stable or improved metrics for at least one release window before full production rollout.
