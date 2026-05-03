## [0.2.0] - 2026-05-03

### Fixed

- `Wallet#transfer_to` now honors `Wallets.configuration.allow_negative_balance`, matching `Wallet#debit`. Previously the flag was half-applied: direct debits could go below zero, but the canonical transfer primitive (used to move value between users) silently rejected any transfer that would push the source below zero. Apps using the flag for a "convenience overdraft" (e.g. ride-fare apps where passengers may briefly go negative until rewards land) had to monkey-patch the gem to get consistent behavior. ([#3](https://github.com/rameerez/wallets/pull/3))
- `:balance_depleted` callback now fires when a debit takes a wallet from a positive balance to **zero or lower** (was: exactly zero). Previously, with `allow_negative_balance = true`, a single debit that drove a wallet from e.g. +100 to -50 would skip the callback because the wallet never landed on exact zero. The callback semantic is "ran out of available value", which is at least as true at -50 as at 0. With `allow_negative_balance = false` the behavior is unchanged because balances cannot go below zero.

### Changed

- When a transfer drives the source wallet below zero AND the caller is using the default `:preserve` expiration policy, the policy automatically falls back to `:none` for that transfer. Rationale: there are no positive source buckets to "preserve" expirations from for the deficit portion, and `build_preserved_transfer_inbound_credit_specs` would otherwise raise `InvalidTransfer`. The inbound credit becomes a single evergreen entry — the only honest representation of "value created without a source bucket". Explicit `:fixed` and `:none` policies are honored unchanged.
- `:insufficient_balance` callback no longer fires for transfers that succeed under `allow_negative_balance = true`. It still fires (and the transfer still raises `Wallets::InsufficientBalance`) when the flag is off and the transfer is rejected.

### Documented

- `apply_credit` does NOT auto-allocate a new credit against existing unbacked debits. The FIFO ledger is intentionally append-only — both the unbacked debit and the new credit persist as independent rows; `balance` reconciles them on the fly. Apps that want automatic debt settlement should layer that on in their own service code.
- `allow_negative_balance` is meant to be a stable config decision, not a runtime toggle. Flipping it OFF while wallets are below zero leaves them un-saveable, since the model's `balance >= 0` validation is gated on the flag and any subsequent `credit` / `debit` calls `refresh_cached_balance!` (which calls `save!`).
- `has_enough_balance?` keeps strict semantics under `allow_negative_balance = true`: it still answers "does this wallet have enough on hand right now?", returning `false` when the gem would happily complete an overdraft. Overdraft is a deliberate caller choice via `debit` / `transfer_to`, not a query semantic.

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
