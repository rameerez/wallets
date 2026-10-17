# Holds and reservations: pending value for `wallets` (0.4.0)

**Status:** revision 2, **signed off** 2026-10-17. Drafted by Claude; reviewed by Astra (Codex, `gpt-6-astra`) over four rounds, the last two on this document. Astra's statement: *"I approve revision 2 as the implementation contract for holds and reservations in `wallets` 0.4.0."* The negotiation transcript is in `2026-10-17-holds-negotiation/` next to this file. Not yet reviewed by the owner.

## 1. Why

Apps need value that **exists in the ledger but is not spendable yet**, on both sides of the statement, using the familiar available/current balance distinction (with one honest difference: here a capture stays conditional on funding, because value can expire):

| bank statement | this gem |
|---|---|
| a deposit that has not cleared | a credit under a **hold** (per credit, or every credit in the wallet) |
| a card charge that is pending until the merchant captures it | a **reservation** of an amount, later **captured** or released |
| **available balance** | `wallet.balance` |
| pending | `wallet.held_balance` |
| current (ledger) balance | `wallet.total_balance` |

Concrete consumers:

- **Fraud and compliance freezes.** A reward was credited; a later signal says "do not let this leave until the counterparty pays us or an operator clears it". Per credit, per set of credits, or the whole wallet. Reversible, auditable, and with a way to *end* the hold in either direction: give the money back, or take it away.
- **Pending and clearing balances.** Marketplace seller earnings unavailable until the return window closes; gig earnings pending until the payout cycle; loyalty points pending until the order is non-refundable.
- **Vesting.** A referral bonus that unlocks after 14 days.
- **Dispute holds.** One credit held while a dispute runs; a second, independent reason on the same credit must be possible.
- **Pending charges.** A booking reserves €30 of a wallet now; the charge is captured for €27.50 when the service is delivered, or falls off after 7 days.

Today the gem has none of this. `balance` counts every non-expired credit, `allocate_debit!` consumes any non-expired credit, there is no wallet state, and the README lists "escrow, pending, available, reserved, delayed-release" under *use something else*. Every workaround fails: not crediting hides the value from the user and cannot be applied retroactively; a metadata flag enforced in the app leaves `balance` lying and every debit path still consumes the flagged credit; parking value in another wallet and back prints two rows in the user's feed and corrupts "total earned" sums.

## 2. Decisions

| # | decision | why |
|---|---|---|
| D1 | **`balance` is the available balance.** Held and reserved value is excluded exactly the way expired value is excluded today. With no holds nothing changes. | "balance means spendable" is the existing contract (expired value is already out). Every `has_enough_balance?`, `debit`, `transfer_to` and every host app's `wallet.balance` gate continues to work unchanged; presentation, analytics and cached-balance checks still need adoption work. A balance you cannot spend is the trap, not the feature. |
| D2 | **One table, one model: `Wallets::Hold`.** No STI, no status enum, no polymorphic target. | Holds on a credit, holds on a wallet and reservations share one lifecycle (active → released or captured, optional deadline), one attribution shape and one balance term. A second table would duplicate all of it for one column and one verb. |
| D3 | **A credit hold has no amount: it restricts the credit's whole remaining value.** Several holds on one credit are independent *reasons*; any active reason keeps it held; the credit is counted once. | Partial holds raise an unanswerable question (two holds of 40: the same 40 or 80?). No stated consumer needs them. Deferred until a consumer proves overlapping vs additive. |
| D4 | **A reservation is a wallet-scoped hold with an amount, and reservations are additive.** Two reservations of 40 reserve 80, like two pending card charges. A credit-scoped row with an amount is rejected. | Amounts only appear where the only sane semantics is additive. Coverage and additive never meet on one row shape, so D3's ambiguity never arises. |
| D5 | **Holds decide which buckets may fund a debit; `allow_negative_balance` decides whether an unfunded debit proceeds.** Same rule for every scope. No `WalletOnHold` error. | One policy, not two. Absolute prohibitions on outgoing activity are application decisions (gate the action in the app; the hold is the explanation the app can render). |
| D6 | **Available balance is a signed integer.** The unconditional `balance >= 0` validation on the cached column goes away. Commands enforce funding under lock. | With reservations, available can legitimately go negative without any overdraft (reserve 80 of 100, then a fraud hold covers the 100). A save-time floor would reject the fraud hold, an incoming credit or a release. The 0.2.0 trap "flipping the flag off leaves wallets unsaveable" disappears with it. |
| D7 | **`from:` on `debit` and `transfer_to` restricts allocation to named credits and may consume coverage-held value.** It is the hold's third ending: release gives the value back, `from:` takes it away. | Without it a fraud hold has no resolution except "give it back" or "keep it forever". Existing reversals via plain `transfer_to` consume FEFO from unrelated credits, so they cannot cancel a specific credit. Allocations already record the source, so no new money object is needed. |
| D8 | **Targeted debits respect reservations and debt.** With overdrafts off: `amount − covered_consumed ≤ max(available_before, 0)`. Always: fully allocated to the named, unexpired sources; no FEFO fallback, no unbacked fallback. | Cancelling a fully held credit must work at zero available; selecting an unheld credit must not defeat an outstanding reservation; an expired source would create value out of nothing on a transfer. |
| D9 | **Capture is one composite transition.** Reservation ends with reason `captured`, a debit is posted and linked by `capture_transaction_id`; snapshots and callbacks see only original and final balances. | A naive release-then-debit reports `0 → 100 → 0` and fires depleted/low-balance callbacks that never happened. |
| D10 | **Scheduled release is computed, like expiry.** No sweeper, no callback at a deadline. `hold_released` fires only for explicit `release!` and for capture. | A worker observing a deadline hours later would invent before/after balances; the app may have spent the value already. Same contract as `expires_at` today. |
| D11 | **`hold_class_name` is the capability switch.** `nil` on `WalletBase` (disabled), `"Wallets::Hold"` on `Wallets::Wallet`. Disabled ledgers run no hold SQL, including on destroy; hold commands raise `Wallets::HoldsNotEnabled`; enabled ledgers fail loudly on a missing table. | Never discover accounting behaviour from table existence; a missing table must not make held value spendable. Embedders (usage_credits) opt in deliberately with their own class, table and balance override. |
| D12 | **`positive_remaining_balance` and `unbacked_negative_balance(scope)` keep both signature and meaning.** New private helpers carry the covered and reserved terms. | usage_credits overrides `current_balance` with them; changing their meaning would silently alter its accounting. |
| D13 | **Public deadline keyword is `until:`; the column and reader are `releases_at`.** One spelling on every command, including inside `hold: { ... }`. | "Hold this until March" is what a person says; `releases_at` mirrors `expires_at` in the schema. The API is unshipped, so one spelling is free. |
| D14 | **Names:** `hold`, `reserve`, `release!`, `capture!`, `held_balance`, `total_balance`, `on_hold?`, `hold_created` / `hold_released`. No additional naming aliases beyond `available_balance`. | `authorize` implies a payment decision the gem does not make; `ledger_balance` is jargon next to available/held/total; `frozen?`/`freeze!` collide with Ruby and Active Record; `balance_held` lies when a second reason moves no balance. |
| D15 | **Ship 0.3.0 as it stands; holds and reservations are 0.4.0** with an upgrade generator. | 0.3.0 is already large and dogfooded by usage_credits, whose `~> 0.3.0` pin keeps it off 0.4.0 until it opts in. |

## 3. Vocabulary

- **Hold:** an independently releasable restriction, recorded as one row of `wallets_holds`. Three shapes:
  - **credit hold** (`transaction_id` set, `amount` nil): the credit's whole remaining value is unavailable while any active hold covers it.
  - **wallet hold** (`transaction_id` nil, `amount` nil): every credit in the wallet, including credits received later, is covered.
  - **reservation** (`transaction_id` nil, `amount` set): `amount` of the wallet's available value is set aside; additive.
- **Coverage** = credit holds + wallet holds. **Reserved** = reservations. Both are "held" to the balance readers.
- **Active:** `released_at IS NULL AND (releases_at IS NULL OR releases_at > now)`. At the exact deadline a hold is inactive, matching `expired` (`<=`) and `not_expired` (`>`).
- **Released:** ended explicitly (`release!`) or by capture. **Lapsed:** deadline passed without an explicit release; inactive, not released, no callback.
- **Capture:** turning a reservation into a posted debit for up to the reserved amount.
- **Targeted debit:** a `debit` or `transfer_to` with `from:`, allocated only against named credits.

## 4. Data model

```ruby
create_table :wallets_holds do |t|
  t.references :wallet,              null: false, foreign_key: { to_table: :wallets_wallets }
  t.references :transaction,         null: true,  foreign_key: { to_table: :wallets_transactions }
  t.references :capture_transaction, null: true,  foreign_key: { to_table: :wallets_transactions },
                                     index: { unique: true }
  t.bigint   :amount                                      # reservations only
  t.string   :category,         null: false               # free-form business reason
  t.datetime :releases_at                                 # scheduled end
  t.datetime :released_at                                 # explicit end (release! or capture)
  t.string   :release_reason
  t.send json_column_type, :metadata,         null: false, default: json_column_default
  t.send json_column_type, :release_metadata, null: false, default: json_column_default
  t.timestamps
end

add_check_constraint :wallets_holds, "amount IS NULL OR amount > 0"
add_check_constraint :wallets_holds, "transaction_id IS NULL OR amount IS NULL"          # D4
add_check_constraint :wallets_holds,
  "capture_transaction_id IS NULL OR " \
  "(transaction_id IS NULL AND amount IS NOT NULL AND released_at IS NOT NULL)"   # only an ended reservation
add_index :wallets_holds, [:wallet_id, :released_at]
add_index :wallets_holds, [:transaction_id, :released_at]
add_index :wallets_holds, :releases_at
```

Same prefix, primary-key type and adapter-aware JSON handling as the existing template (`index_name` / `constraint_name` helpers). Ordinary composite indexes, no partial indexes as a correctness dependency (MySQL). `category` is a free-form label, not validated against transaction categories and deliberately not unique.

Model-level validations (row-local): `category` present; `amount` nil or a positive whole number (`Wallets::WholeNumber`); `transaction_id` present ⇒ `amount` nil; `capture_transaction_id` present ⇒ `transaction_id` nil, `amount` present and `released_at` present (a coverage hold can never carry a capture link). Cross-record rules (target ownership, remaining value, funding) are checked under the wallet lock by the commands, never by `validate`. Capture verifies under lock that the linked transaction is a debit in the same wallet and that its absolute amount does not exceed the reservation amount.

Deletion contract (extends the existing one, which cascades an owner's whole history): hold associations are installed only on enabled concrete ledger classes (`Wallets::Wallet`, `Wallets::Transaction`), never on the abstract bases (D11). An enabled wallet uses a **prepended `before_destroy` callback** (`before_destroy ..., prepend: true`) to destroy its holds before the transaction and transfer dependencies already declared on `WalletBase` run; declaring the association on the subclass alone would not place its callback first. Destruction remains transactional: a failed hold destruction aborts the wallet destruction. Disabled ledgers install no hold-dependent destruction behaviour. Concrete transactions declare their credit-hold association (`has_many :holds`) and the inverse `has_one :captured_reservation, foreign_key: :capture_transaction_id` **without** `dependent: :nullify`: the foreign key protects a retained capture link, and nullifying it could erase the capture identity while a surviving reservation still reads `"captured"`. Wallet destruction succeeds because its holds have already been destroyed. Tested on PostgreSQL and MySQL, where the FKs are enforced.

Hold commands retain rows; owner and wallet destruction follow the cascade contract above. Release is one-way; creation facts are immutable.

## 5. Semantics

One evaluation instant `now` per mutation, sampled after the wallet lock is held and used for expiry, scheduled release, eligibility and snapshots. Public scopes keep their `Time.current` default; internally every scope takes `at:`.

```
P  = Σ remaining value of unexpired credits                     (today's positive_remaining_balance)
N  = Σ unbacked value of debits                                 (today's unbacked_negative_balance)
C  = Σ remaining value of unexpired credits covered by ≥1 active credit hold, or by any active wallet hold
R  = Σ amount of active reservations

balance (available) = P − C − R − N
held_balance        = C + R
total_balance       = P − N                                      (today's balance)
```

Invariants and consequences:

- `total_balance == balance + held_balance` for the same database snapshot and instant. One evaluation timestamp does not guarantee one database snapshot across several queries: each calculation derives its components consistently, and separate public reader calls may observe intervening mutations.
- `held_balance` may exceed `total_balance` (coverage over reserved value; expiry removing backing). Not capped.
- `balance` may be negative with `allow_negative_balance: false` (D6). The configuration contract becomes: *`allow_negative_balance` permits commands to exceed available funding; disabling it does not guarantee that available balance never goes negative through expiry or new restrictions.*
- A transaction's readers: `remaining_amount` unchanged; `held_amount` = the unexpired remainder if the credit is covered, else 0; `available_amount` is zero for expired credits and for debits, otherwise `remaining_amount − held_amount`; `held?` = `held_amount.positive?`. These readers account for expiry and coverage only: wallet reservations and unbacked debt are enforced at wallet level and are not apportioned among individual credits. Wallet holds affect them too. Reasons stay inspectable after expiry zeroes `held_amount`.
- `wallet.on_hold?` = an active **wallet hold** exists (coverage only; a pending booking is not a blanket hold). True on an empty wallet, because future credits are covered.
- FEFO allocation consumes only **eligible** credits: unexpired and not covered. Reservations do not pin buckets; they are enforced by affordability. Ordinary debits therefore leave a reservation backed by the longest-lived buckets while sufficient backing remains (overdraft-enabled spending can leave reservations underfunded, see §6.5).
- Expiry is not paused by a hold. A reservation can become underfunded through expiry; capture is subject to funding at capture time.
- SQL shape: the covered term is a `CASE WHEN EXISTS(...)` per credit (plus one `EXISTS` for a wallet hold), reserved is one `SUM` over active reservations. No join from credits to holds and allocations at once (it would multiply amounts). Affordability and allocation share one eligibility definition (one Ruby predicate backed by one SQL fragment), so they can never disagree.
- The cached `balance` column holds available balance and, as today, can go stale through time (expiry, lapsed deadlines). SQL readers must not treat it as authoritative.

## 6. Operations

Every command: `with_lock` on the wallet (transfers lock the pair in id order as today), `requires_new: true` savepoint, `now` sampled after the required wallet locks are held, one cache refresh, snapshots and callbacks from original and final balances. Success callbacks are registered for delivery after the outermost commit; `insufficient_balance` remains immediate, fires once per rejected funding attempt, and does not depend on a later commit.

Authoritative reads include every accounting term: mutation-time reads of credits, allocations, unbacked debt, coverage and reservations require **current-read semantics**. Under MySQL repeatable read, a transaction's consistent snapshot is fixed by its first read; taking the wallet lock afterwards does not refresh it, and ordinary aggregate `SELECT`s run after the lock still see the old snapshot. The accounting reads a mutation decides on must therefore see current rows; a plain `SUM` after `lock!` is not enough. The test in §11 ("reads first, waits, then locks") pins this.

**Implementation decision (step 3, 2026-10-17; supersedes "always locking reads").** Locking every accounting read on MySQL is correct but not safe to run: InnoDB takes gap locks on the index ranges those reads scan, and the gaps after one wallet's newest rows are the gaps other wallets insert into, so unrelated concurrent debits and sign-ups deadlocked each other in about a tenth of a 300-attempt stress run. Locking reads are therefore used **only when this transaction's snapshot is stale for this wallet**: after the wallet lock is granted, the transaction's snapshot copy of the wallet row (`updated_at`, `balance`, read with a plain `SELECT`) is compared with the locked row; a difference means something was committed to this wallet after the snapshot, and every accounting read of that mutation (and of every later mutation in the same transaction, the verdict being remembered until commit or rollback) is a locking read, including the correlated allocation and hold subqueries. This rests on one invariant that every command must keep: **every committed change to a wallet's ledger writes the wallet row with a strictly increasing `updated_at`** (`refresh_cached_balance!` saves it when the balance moved and otherwise writes `updated_at` directly, bypassing `no_touching`, to the later of now and the previous value plus one microsecond; datetime precision 6 assumed, the Rails 7+ default), which is also what makes PostgreSQL's repeatable read detect a concurrent update on `lock!`. The stale verdict lives exactly as long as the real (outermost) database transaction, never a savepoint. Because a caller's own Active Record write to the wallet row inside the same transaction would make the row look fresh while the ledger snapshot is not, a wallet already saved or touched by the current transaction is treated as stale (conservative; creating the wallet and the ledger's own cache refresh are exempt, since neither can hide another transaction's commit); raw-SQL writes to the wallet row (`update_columns`, SQL), and holds or reservations created outside the wallet commands, are outside the supported API.

Success callbacks are queued on the innermost open transaction, the command's own savepoint, exactly as Active Record's own `after_commit` does: a failure later in the command drops them, a released savepoint hands them to its parent, an enclosing rollback drops them, and a `transaction(joinable: false)` boundary counts as a commit, as it does for Active Record (transactional test fixtures rely on that). Only the stale verdict needs the real transaction's lifetime. PostgreSQL (read committed, fresh snapshot per statement) and SQLite (serialised writers) never need the locks. Public readers never lock.

**Readers are one statement (review finding, 2026-10-17).** P, C and N come from one query over the wallet's transactions, with R as a scalar subquery over active reservations in the same statement, so `balance`, `held_balance` and `total_balance` each derive from one database snapshot and the identity holds within a reader call even on read-committed PostgreSQL, where separate statements see separate snapshots.

### 6.1 Credit with a hold

```ruby
wallet.credit(751, category: :reward, hold: :pending_validation)
wallet.credit(751, category: :reward, hold: { category: :pending_validation, until: 3.months.from_now, metadata: { ride_id: ride.id } })
wallet.credit(500, category: :reward, available_at: 14.days.from_now)   # hold of category :pending, until: available_at
```

Composite: the credit and its hold both exist before the balance snapshot and the callback payloads; the `credited` callback reports the credited amount with available before/after of the completed operation (no fictitious spendable instant); `hold_created` fires too. `available_at:` already reached means available now, no hold. `available_at:` combined with `hold:` is an `ArgumentError`. On a disabled ledger (D11) both keywords raise `Wallets::HoldsNotEnabled` before any credit is created, including when `available_at:` has already passed. Returns the credit; `credit.holds` reaches the hold.

### 6.2 Hold an existing credit, or the wallet

```ruby
hold = wallet.hold(credit, category: :fraud_review, until: nil, metadata: { case_id: })
hold = wallet.hold(category: :fraud_review, metadata: { case_id: })   # whole wallet, future credits included
```

Target rules: persisted, a credit (positive), unexpired at `now`, in this wallet's ledger class, owned by this wallet, with remaining value; an already-held credit is a valid target (independent reason). An `until:` already reached raises `Wallets::InvalidHold` (silently creating an inactive restriction would hide a caller error). Omitting the credit holds the whole wallet; passing an explicit `nil` raises `ArgumentError`, so a failed lookup can never freeze a wallet by accident. Fires `hold_created`.

### 6.3 Reserve

```ruby
reservation = wallet.reserve(3_000, category: :booking, until: 7.days.from_now, metadata: { booking_id: })
```

Funding rule: `amount ≤ balance` at `now` unless `allow_negative_balance` (same rule as a debit; the `insufficient_balance` callback fires with `held:` and `reserved:` in its metadata and `Wallets::InsufficientBalance` is raised). Under a wallet coverage hold, `balance == −R − N`: with overdrafts disabled a positive new reservation is rejected; with overdrafts enabled reservation creation remains permitted. Fires `hold_created` with `amount`.

### 6.4 Release

```ruby
hold.release!(reason: "cleared_by_operator", metadata: { actor_id: operator.id })
```

Locks the **wallet first**, then reloads the hold. Idempotent: an inactive hold (released, lapsed or captured) is a no-op that preserves the existing attribution and fires nothing. Otherwise sets `released_at = now`, `release_reason`, `release_metadata` (never overwriting creation `metadata`), refreshes the cache, fires `hold_released`. Returns the hold. Sets are released by ordinary composition under `wallet.with_lock` (no relation-level `release_all`, deliberately: an operator clears the exact reviewed set, never a category).

### 6.5 Capture

```ruby
debit = reservation.capture!(2_750, category: :booking_charge, metadata: { booking_id: })   # amount defaults to the reserved amount
reservation.capture_transaction   # the debit
```

Under one wallet lock and savepoint: reload the reservation; sample `now` after the required wallet locks are held; validate that it is a reservation and is active and uncaptured at that same `now` (the deadline check uses the operation's evaluation instant); record the original balances; exclude this reservation from `R`; check and allocate an ordinary debit for `amount` against eligible credits (other reservations fully in force; coverage-held credits are not touched, so a later fraud hold can make a capture fail); finalize `released_at`, `release_reason: "captured"`, `capture_transaction_id`; refresh the cache; snapshots and callbacks from original and final balances only (a full capture of a fully reserved wallet reports available `0 → 0`). Fires `debited` and `hold_released` (context `transaction` = the debit).

With overdrafts enabled, capture may proceed despite insufficient available funding. It consumes eligible credits first; this can leave other reservations underfunded, and only the portion exceeding the eligible credit remainder becomes unbacked debt. Example: 100 in credits and two reservations of 80; capturing either for 80 leaves 20 in credits, an outstanding reservation of 80, available −60 and **no unbacked debit**. Insufficient availability and insufficient credit buckets are different conditions.

Failure diagnostics: when a capture is rejected for funding, the `insufficient_balance` context carries the wallet's original available balance as both `previous_balance` and `new_balance` (nothing moved), and separately reports the funding available after excluding the captured reservation (`available_for_capture:` in the metadata, next to `held:` and `reserved:`). A failed capture must neither report a fictitious intermediate balance nor claim that no funding existed.

Terminal rules: only an active reservation can be captured; one-shot, positive whole number ≤ the reserved amount; a smaller capture releases the whole remainder; a lapsed or released reservation cannot be captured; a second capture raises `Wallets::InvalidHold` and creates nothing; `release!` after capture is a no-op. A failed capture rolls back all persisted changes; the reservation remains capturable if it is still active when a later attempt acquires the wallet lock (a rollback cannot stop its deadline from passing). The gem never returns an existing debit for a repeated request (its amount or category could differ); apps reconcile through `capture_transaction`.

### 6.6 Targeted debits and transfers (`from:`)

```ruby
wallet.debit(751, category: :reversal, from: credit, metadata: { reason: "reward_rejected" })
wallet.transfer_to(platform.wallet, 751, category: :reversal, from: credit)
wallet.debit(150, category: :reversal, from: [first_credit, second_credit])   # caller order
```

Sources: one credit or an ordered array; reject empty, duplicates, foreign wallet or ledger class, debits, expired at `now` (even under `expiration_policy: :none`). Allocation walks the named sources in order and **may consume coverage-held value**; the debit is always fully allocated to them (`amount ≤ Σ unexpired remaining of the sources`, else `Wallets::InsufficientBalance`; no FEFO fallback, no unbacked part whatever the flag says). Funding with overdrafts off: `amount − covered_consumed ≤ max(available_before, 0)`, where `covered_consumed` is the part of the allocation taken from covered credits; so cancelling a fully held credit works at zero available, does not deepen an existing deficit, and selecting an unheld credit cannot defeat an outstanding reservation. With overdrafts on, named credits may be consumed despite insufficient availability. Holds are untouched: a cancelled credit keeps its reasons with `held_amount` zero; no `hold_released` fires (nothing was released). Documented prominently beside `from:` as the mode that can consume held value.

### 6.7 Changes to existing behaviour

- `apply_debit` / `transfer_to` affordability reads available balance (D1). The `insufficient_balance` callback metadata gains `held:` and `reserved:`; the error message names them.
- The `:preserve` → `:none` transfer fallback is decided by whether the outbound debit **actually has an unbacked portion**, not by `amount > previous_balance`. A fully backed transfer at zero available (targeted from a held credit, or ordinary with reservations outstanding) keeps the source buckets' expirations. This also changes behaviour **without holds**: a transfer that exceeds net available balance because of pre-existing debt but is fully allocated from later credits now preserves expiry where 0.2/0.3 collapsed it to `:none`. Tested (§11) and called out in the CHANGELOG.
- The `balance >= 0` validation is removed (D6). `balance` stays `only_integer`.
- `history` unchanged; holds are not transactions and never appear in it.

## 7. API reference

| surface | shape |
|---|---|
| commands | `credit(amount, hold: Symbol \| Hash)`, `credit(amount, available_at:)`, `hold(credit = nil, category:, until: nil, metadata: {})`, `reserve(amount, category:, until: nil, metadata: {})`, `hold.release!(reason: nil, metadata: {})`, `reservation.capture!(amount = nil, category:, metadata: {})`, `debit(..., from:)`, `transfer_to(..., from:)` |
| wallet readers | `balance`, `available_balance` (delegates to `balance`), `held_balance`, `total_balance`, `on_hold?`, `holds` |
| hold readers | `active?(at: Time.current)`, `released?`, `lapsed?`, `captured?`, `reservation?`, `coverage?`, `wallet_scoped?`, `credit_scoped?`, `capture_transaction`, `credit` (the covered credit; the column stays `transaction_id`, but Active Record defines `#transaction` on every record and refuses an association by that name), `wallet` |
| transaction readers | `holds`, `held?`, `held_amount`, `available_amount`, `captured_reservation` |
| scopes | `Hold.active(at:)`, `.released`, `.coverage`, `.reservations`, `.wallet_scoped` (transaction nil), `.credit_scoped`, `wallet.holds.coverage.active`, `wallet.holds.reservations.active`, `credit.holds.active` |
| errors | `Wallets::InvalidHold` (an unholdable target, a deadline already reached, a wrong state such as capturing an ended reservation), `Wallets::HoldsNotEnabled`, existing `Wallets::InsufficientBalance` for every funding failure, `ArgumentError` for malformed input (a non-numeric or non-positive amount, a deadline that is not a time, conflicting or unknown keywords, an explicit `nil` credit, a capture amount above the reservation) |
| callbacks | `on_hold_created`, `on_hold_released`; `CallbackContext#hold`; event-map keys `hold_created:` / `hold_released:` (embedders may `nil` them) |

Not in this release, on purpose: partial credit holds, `forfeit!`, `release_all`, `held:` / `credit(...).hold(...)` chaining, a deadline sweeper, deadline notifications, bucket pinning for reservations, action prohibitions, STI.

## 8. Embedding

- `WalletBase.hold_class_name` defaults to `nil`; `Wallets::Wallet` sets `"Wallets::Hold"`. `holds_enabled?` = present. When disabled: balance SQL omits the C and R terms, `hold` / `reserve` / `from:` raise `Wallets::HoldsNotEnabled`, destroy issues no hold queries.
- `Wallets::HoldBase` (abstract, `Embeddable`, `HasMetadata` for the creation `metadata` column plus equivalent handling for `release_metadata`: indifferent access, nil normalisation, persistence of in-place changes and cache invalidation on reload. The existing concern hard-codes `metadata`, so the second column needs the same behaviour, either by generalising the concern to take a column name or by a sibling implementation; this matters immediately on MySQL, where the new column has no object default. `table_suffix = "holds"`) and `Wallets::Hold`. `TransactionBase` gains nothing table-bound; the concrete `Wallets::Transaction` declares the two hold associations.
- With holds disabled, `current_balance` is exactly the 0.3 formula, `positive_remaining_balance − unbacked_negative_balance`, through the two helpers an embedder may override; `held_balance` returns zero, `on_hold?` returns false, and `available_balance` and `total_balance` delegate to the dynamic `balance` without hold SQL. Opted-in embedders with custom balance policies must define coherent available, held and total readers; overriding `current_balance` alone must not accidentally violate the balance identity. This preserves usage_credits' custom view when it broadens its dependency without enabling holds.
- usage_credits: unaffected (pin `~> 0.3.0`). Opt-in recipe documented: subclass `HoldBase`, set `embedded_table_name`, declare associations, set `hold_class_name`, run its own migration, and deliberately decide how its `current_balance` override treats C and R (its refund-only debt treatment and zero floor are preserved because D12 leaves the two helpers alone).

## 9. Generators and upgrade

- `rails generate wallets:install`: template gains the holds table (fresh installs).
- `rails generate wallets:upgrade`: emits `add_wallets_holds` for existing 0.1, 0.2 and 0.3 installations. Foreign-key column types match the existing referenced tables (read from the schema when the migration runs), rather than assuming the application's current generator settings match its historical schema. Repeated invocation does not emit duplicate migrations; when the holds table already exists at generation time the generator says so and writes nothing; the migration's `up` is a no-op when the table exists, and its `down` drops the table only when it is empty, otherwise it raises `ActiveRecord::IrreversibleMigration` naming the table (a rollback must never delete holds this migration did not create). Honours the table prefix. Documented in CHANGELOG and README as the one step for 0.4.0.
- Tests: generator runs; up and down on SQLite, PostgreSQL, MySQL; the normal **0.3 → 0.4** upgrade path (the immediate one under D15) plus upgrades from a 0.2 schema, with a custom prefix, with uuid keys, and with historical key types that differ from the current generator settings.

## 10. Callbacks and initializer

`Configuration` gains `on_hold_created` / `on_hold_released` and their readers; the initializer template documents them with the bank model in one paragraph. `CallbackContext` gains `:hold`. Context fields per event: `hold`, `wallet`, `amount` (reservations), `category`, `previous_balance`, `new_balance` (available), `transaction` (capture debit on `hold_released`), `metadata`.

Metadata payload: `hold_created` carries the hold's creation metadata; an explicit `hold_released` carries the release metadata; capture attribution is reached through the context's linked debit transaction (capture metadata lives on the debit, not duplicated on the hold).

Threshold callbacks: each successful mutation evaluates the low-balance and depleted crossings once, from its original and final available balances. This includes coverage creation, reservation creation and targeted debits (all of which can lower available balance). Composite credit and capture operations never evaluate intermediate states. Deadline passage emits no threshold callbacks. Idempotent no-ops emit no callbacks.

## 11. Acceptance tests (minimum)

Balance and eligibility: credit hold excludes value from `balance` and from FEFO; two reasons on one credit count once; releasing one reason keeps the other; wallet hold covers a later credit; exact deadline boundary (inactive at `releases_at`); expiry under a hold zeroes `held_amount` and keeps reasons; expired credits report zero `available_amount` whether previously covered or not; `total == available + held` at a snapshot; `held > total` cases.

Shape and links: coverage rows reject capture links (check constraint and validation); captures reject a foreign-wallet debit, a credit, or a debit larger than the reservation.

Signed availability (D6): reserve then cover makes available negative with overdrafts off; incoming credit and release succeed in that state; expiry makes available negative and the wallet stays saveable.

Reservations and capture: funding rule with and without overdrafts; additive reservations; full capture `0 → 0` snapshots and no threshold callbacks; smaller capture releases the remainder; capture after lapse/release raises; capture versus release and capture versus capture on PostgreSQL and MySQL serialise to one terminal transition, asserting the event set (a successful capture emits one `debited` and one `hold_released`; a successful explicit release emits one `hold_released`; losing attempts emit no success events); capture failing without partial release; capture blocked by a later coverage hold; with overdrafts on, a capture funded by credit buckets but underfunded relative to other reservations creates **zero** unbacked amount, and a capture exceeding the eligible buckets creates exactly the residual unbacked amount; failed-capture diagnostics report the original balance and the funding available after excluding the reservation.

Targeted (D7, D8): cancel a fully held credit at zero available; cannot deepen a deficit; cannot defeat a reservation by naming an unheld credit; ordered multi-source; expired source rejected under every expiration policy; fully backed targeted transfer at zero available keeps `:preserve`; no `hold_released` on cancellation; allocations name the sources.

Transfer fallback without holds: pre-existing debt, later credits, a transfer exceeding net available but fully allocated now preserves expiry (the documented behaviour change in §6.7).

Composite credit: credit-with-hold atomic under a caller's rescued failure (savepoint); callback payloads show no intermediate spendable balance; disabled ledger rejects `hold:` and `available_at:` (even already passed) before any credit exists.

Callbacks: reservation and coverage creation fire threshold callbacks once on a real crossing, and overlapping reasons do not repeat the crossing; failed captures and transfers emit no success callbacks even when the caller rescues and commits its surrounding transaction, while funding failures still emit the immediate `insufficient_balance`; success callbacks dropped on outer rollback.

Concurrency (PostgreSQL and MySQL): MySQL repeatable-read transaction that reads first, waits for another transaction to create a hold, then takes the wallet lock and sees it; concurrent hold versus debit on the same credit: if the hold wins, ordinary spending excludes that credit; if spending exhausts the credit first, hold creation fails cleanly; neither ordering leaves partial writes; lock order wallet-then-hold on `release!`; concurrent releases produce one transition.

Embedding and lifecycle: disabled ledger runs zero hold queries (assert via query subscriber) including destroy, and preserves an overridden balance policy; `HoldsNotEnabled` raised; wallet destruction proves holds are removed before the inherited transaction dependencies and that retained capture links are not nullified, with both FKs enforced on PostgreSQL/MySQL; both JSON columns handle nil, reload and in-place changes; upgrade generator paths including 0.3 → 0.4 and historical key types.

Coverage gate stays at 98 % line / 85 % branch.

## 12. Implementation sequence

1. Schema: install template, upgrade generator, `HoldBase` / `Hold`, associations, validations, scopes. Tests for shape and destroy.
2. Balance: `at:` plumbing, covered and reserved terms, signed cache (D6), readers, transaction readers. Tests.
3. Eligibility: shared predicate, `allocate_debit!` skipping covered credits, `insufficient_balance` metadata. Tests.
4. Commands: `hold`, `reserve`, `release!`, composite `credit(hold:)` / `available_at:`. Callbacks and configuration. Tests.
5. `from:` on `debit` and `transfer_to`, funding rule, `:preserve` fallback by actual unbacked portion. Tests.
6. `capture!`. Race tests on PostgreSQL and MySQL.
7. README section "Holds and reservations" (bank model, the three shapes, `from:` warning, embedding recipe, upgrade), CHANGELOG 0.4.0, initializer template, RBS stubs.

One PR per step or one PR with these commits; CI green on the full matrix before release.

## 13. Follow-ups (not blocking)

- usage_credits opt-in, when it wants pending credits.
- Inbound holds on transfers (`transfer_to(..., hold:)`, pending marketplace payouts): same composite as 6.1 applied to each inbound leg. Proposed for 0.4.x once 6.1 is in. The 0.4.0 README states the limitation plainly: `transfer_to` cannot yet issue recipient credits under an atomic initial hold; the recipient side holds them with `wallet.hold(credit, ...)` after the transfer, which is not atomic with it.
- CarHey adoption (separate plan): render available / held on the wallet screen and a "retenido" chip on held rows; keep `Fraud::PayoutHold` as the action gate while the hold becomes the explanation; teach the cached-balance health check and the balance analytics the available / total split.
