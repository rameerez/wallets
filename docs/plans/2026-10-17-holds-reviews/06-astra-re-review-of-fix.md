# Re-review of the fix commit (Codex Astra, 2026-10-18, at commit 3e0d8ae)

Scope: the delta that answered the final review (ledger_revision marker, Trilogy detection, capture-link validation, hold error order, cached-balance validation). Verdict: PASS; three wording nits applied in the next commit.

## Blocking

None verified.

## Should fix

None verified.

## Nits

- [Plan:128](/Users/javi/GitHub/wallets-holds/docs/plans/2026-10-17-holds-and-reservations.md:128) still describes comparing `updated_at` and `balance`; update that sentence to `ledger_revision`.
- [Plan:225](/Users/javi/GitHub/wallets-holds/docs/plans/2026-10-17-holds-and-reservations.md:225) still says the holds table alone makes generation and migration unnecessary; both table and column are now required.
- [hold.rb:21](/Users/javi/GitHub/wallets-holds/lib/wallets/models/hold.rb:21) says validation is exclusively row-local; mention the new capture-link validation exception.

## Missing tests

- Legacy fallback under real MySQL repeatable read: the added test uses `ignored_columns` and a simulated marker mismatch, rather than two connections against a columnless table.
- Actual Trilogy install/upgrade execution: adapter detection is tested through name stubs only.

This delta introduces no verified release blocker for 0.4.0. The counter closes the reviewed timestamp-rewind hole, and the migration, capture validation, error ordering and cached-balance changes match the intended fixes. This is a static review; I did not rerun the reported 532-test adapter matrix.

VERDICT: PASS