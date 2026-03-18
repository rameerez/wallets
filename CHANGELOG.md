## [0.2.0] - 2026-03-18

- Add embeddability hooks so other gems, including `usage_credits`, can reuse the wallet ledger core with their own tables, callbacks, and configuration
- Widen stored ledger values to `bigint` and harden transfer/class isolation for coexistence in the same Rails app
- Expand the runtime test suite and documentation for production-ready internal balances, transfers, and multi-asset wallet use cases

## [0.1.0] - 2026-03-15

- Extract the neutral wallet ledger core from `usage_credits`
- Add multi-asset wallets per owner via `has_wallets`
- Add generic `credit`, `debit`, and `transfer_to` APIs
- Keep append-only transactions, FIFO allocations, expirations, and callbacks
- Add a neutral install generator, dummy app, and test suite
