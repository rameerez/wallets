## [0.1.0] - 2026-03-18

Initial release.

- Multi-asset wallets per owner via `has_wallets` — `user.wallet(:usd)`, `user.wallet(:gems)`, etc.
- Append-only transaction ledger with `credit`, `debit`, and `transfer_to` APIs
- FIFO allocation for expiring balances — oldest credits consumed first
- Transfer expiration policies: `:preserve` (default), `:none`, `:fixed`
- Transfers split into multiple inbound legs when consuming buckets with different expirations
- Embeddability hooks for other gems to reuse the ledger core with custom tables/config/callbacks
- Idempotent `create_for_owner!` with race condition handling
- Row-level locking to prevent double-spending
- Balance snapshots on every transaction for reconciliation
- Rich metadata support on wallets, transactions, and transfers
- Lifecycle callbacks: `on_balance_credited`, `on_balance_debited`, `on_transfer_completed`, etc.
- Install generator with migrations and initializer
- Rails 6.1+ support (tested through Rails 8.x)
