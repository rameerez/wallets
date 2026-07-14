## [0.3.0] - Unreleased

### Fixed

- **Host app model shadowing.** The engine no longer adds the gem's `lib` directories to the host app's autoload paths. Those paths made Zeitwerk claim top-level constants like `::Wallet`, `::Transaction`, `::Transfer`, and `::Allocation` — so any host app with its own model by one of those (very common) names found it shadowed and unresolvable (`NameError: uninitialized constant Transaction`). All gem code is required eagerly by `lib/wallets.rb`, so the autoload paths were never needed.
- **Owners with transfer history could not be destroyed.** `Wallets::Transfer#transactions` now uses `dependent: :nullify`. Previously, destroying a wallet (or its owner) that had ever sent or received a transfer raised `ActiveRecord::InvalidForeignKey`: the transfer row was destroyed while the counterparty's ledger row still pointed at it. Now the link object is cleared while both sides' ledger rows — and the counterparty's balance — survive intact; transaction metadata still carries `transfer_id` and counterparty details for audit.
- **`create_for_owner!` race recovery now works on PostgreSQL.** The duplicate-insert rescue ran inside the same transaction as the failed `INSERT`. On PostgreSQL a unique-index violation aborts that transaction, so the recovery `SELECT` raised `PG::InFailedSqlTransaction` instead of returning the winner's wallet — precisely in the concurrent-creation scenario the rescue exists for. The create now writes through a savepoint (`requires_new: true`) and rescues outside it, which also keeps a caller's surrounding transaction (e.g. `after_create` wallet auto-creation) usable after a lost race.
- **`belongs_to` requiredness is now explicit.** The gem's models load before Rails applies `belongs_to_required_by_default`, so all ledger associations were silently optional: an orphan `Transaction`/`Allocation`/`Transfer` passed validation and crashed later with a database-level `NotNullViolation`. All required associations now declare `optional: false` and fail with friendly validation errors regardless of host app configuration or load order.
- **`has_wallets` options now reach subclasses.** Wallet options were stored in a class-level ivar that STI/inheritance never saw, so a subclass of a model with `has_wallets default_asset: :coins` silently fell back to the global default asset. Options are now resolved lazily through the ancestor chain; subclasses inherit their parent's declaration and can override it with their own `has_wallets`. Lazy resolution also means `Wallets.configuration.default_asset` is honored no matter when the host app's initializer ran relative to model loading.
- **Unknown callback events no longer break ledger writes.** `Wallets::Callbacks.dispatch` promised error isolation but raised `NoMethodError` (mid-transaction!) when handed an event with no matching `on_<event>_callback` reader — e.g. from an embedded subclass with a custom `callback_event_map` but the default callbacks module. Unknown events are now ignored.
- `transfer_to` raises a friendly `Wallets::InvalidTransfer` ("Source wallet must be persisted") instead of a confusing `ArgumentError` from internal lock ordering when called on an unpersisted wallet.
- Amount validation no longer leaks internal errors: `credit`/`debit`/`transfer_to` with `Float::INFINITY`, `Float::NAN`, or a non-numeric like a `Symbol` now raise `ArgumentError` (previously `FloatDomainError`/`NoMethodError`), and `has_enough_balance?` returns `false` for them instead of crashing.
- `expires_at` given as a `String` is now validated by parsing it (`"2030-01-01"` works; garbage raises a clear `ArgumentError`). Previously any string — valid or not — crashed with "comparison of String with Time failed".
- `wallet()` on an unsaved owner raises `Wallets::Error` instead of a bare `RuntimeError`, so `rescue Wallets::Error` catches everything the gem raises.
- `Transaction.expired` scope and `Transaction#expired?` now treat a transaction expiring exactly "now" as expired (`<=` instead of `<`), matching `not_expired` and the balance math, so the two scopes partition the ledger cleanly at any instant.
- The install initializer template now lists the gem's real default categories (it previously mentioned `:transfer` and `:expiration`, which don't exist).
- `Appraisals` was out of sync with `gemfiles/` and CI (it listed Rails 6.1–8.0; the tested matrix is Rails 7.2 and 8.1).

### Changed

- `Wallet#history` orders by `created_at` with `id` as tiebreaker, so same-instant transactions (e.g. both legs of a transfer) have a deterministic order.
- `transfer_to` opens its transaction via the wallet class (`self.class.transaction`) instead of `ActiveRecord::Base.transaction`, so embedded wallet subclasses connected to a different database transact on the right connection.
- `Wallets::Railtie` is retained as a compatibility alias for `Wallets::Engine`; the engine remains the actual Rails integration point.
- `Wallets::Transfer` now validates `category` presence at the model layer instead of failing with a database `NOT NULL` violation.
- Successful lifecycle callbacks run only after the caller's outermost database transaction commits; a later rollback now drops them entirely. Rails 7.2's callback API is required for this guarantee.
- Ruby 3.2 and Rails 7.2.3.1 are now the minimum supported runtime versions. Current security-patched Rails dependency releases cannot be installed on Ruby 3.1, and earlier Rails 7.2 patch releases contain known vulnerabilities.
- Expiring value is consumed first (FEFO), with oldest-first ordering as the deterministic tie-breaker. Documentation now names this behavior accurately instead of calling every allocation FIFO.

### Added

- `Wallets.normalize_asset_code(value)` — the single source of truth for asset code normalization (`" EUR "`, `:EUR`, and `"eur"` all name the same wallet), used consistently across configuration, wallets, transfers, and owner lookups.
- `Wallets::Embeddable` concern — the embeddability plumbing (`embedded_table_name`, `config_provider`, `resolved_config`, prefix-derived table names) extracted from the four models into one place. Embedded subclasses without an explicit `embedded_table_name` derive `"#{config.table_prefix}#{table_suffix}"` automatically.
- `Wallets::HasMetadata` concern — the indifferent-access metadata behavior (hash coercion, mutation-safe saves, NULL-column healing for MySQL) extracted from the three metadata-carrying models into one place.
- `Wallets::WholeNumber` — one strict integer parser shared by the core ledger and embedding gems, eliminating silent float/string truncation across amount and threshold boundaries.
- An explicit transaction-attribute allowlist for embedded ledgers, preventing extension keywords from overwriting core accounting fields.

### Tests

- Test suite grew from 92 runs / 338 assertions to 200 runs / 741 assertions. Line coverage 93.45% → 100%, branch coverage 65.93% → 98.91%; the SimpleCov gate is raised to 98% line / 85% branch.
- New regression tests for every fix above, including a real duplicate-insert race executed inside a caller's transaction (exercises PostgreSQL savepoint semantics in CI), destroy cascades with transfer history, FEFO allocation order, expiration boundary partitioning, amount/expiration edge cases, callback logging fallbacks, and STI wallet-option inheritance.
- The install generator now runs in tests, and its generated migration is executed (up and down) against the real database adapter in CI.
- Compatibility coverage includes Ruby 3.2 across both the Rails 7.2 and Rails 8.1 boundaries, Ruby 3.3/3.4/4.0 across both Rails lines, and clean migrations plus the full suite on SQLite, PostgreSQL, and MySQL.
- CI audits every supported dependency bundle against the latest `ruby-advisory-db` before release.

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
