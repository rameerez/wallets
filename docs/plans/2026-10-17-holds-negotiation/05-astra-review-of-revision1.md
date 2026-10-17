## Sign-off review

The negotiated shape is sound. The plan needs the following corrections before it can serve as the implementation contract.

**§1 — Why: OK.**

**§2 — Decisions: OK.** D1–D15 capture the agreed decisions.

**§3 — Vocabulary: OK.**

**§4 — Data model: changes required.**

Replace:

> `add_check_constraint :wallets_holds, "capture_transaction_id IS NULL OR released_at IS NOT NULL"`

With:

```ruby
add_check_constraint :wallets_holds,
  "capture_transaction_id IS NULL OR " \
  "(transaction_id IS NULL AND amount IS NOT NULL AND released_at IS NOT NULL)"
```

Mirror this stronger condition in the row-local model validation. As written, a credit hold or wallet coverage hold can carry a capture link.

Also add this sentence after the cross-record rules:

> Capture verifies under lock that the linked transaction is a debit in the same wallet and that its absolute amount does not exceed the reservation amount.

Replace the deletion-contract paragraph, beginning:

> `WalletBase` declares `has_many :holds, dependent: :destroy` **before** `has_many :transactions`…

With:

> Hold associations are installed only on enabled concrete ledger classes. An enabled wallet uses a prepended `before_destroy` callback to destroy its holds before inherited transaction and transfer dependencies run. Destruction remains transactional: a failed hold destruction aborts the wallet destruction. Disabled ledgers install no hold-dependent destruction behavior. Concrete transactions declare their credit-hold association and the inverse `captured_reservation` association. The capture association does not use `dependent: :nullify`; the foreign key protects a retained capture link. Wallet destruction succeeds because its holds have already been destroyed.

The current paragraph contradicts itself about abstract versus concrete declarations. More materially, adding an association to the concrete subclass does not place its callback before the transaction dependency already declared on `WalletBase`. Rails explicitly provides `prepend: true` for this ordering problem. [Rails callback ordering](https://guides.rubyonrails.org/active_record_callbacks.html#cascading-association-callbacks)

I would strike the proposed nullification “belt and braces”: it could erase the capture identity while leaving a surviving reservation whose reason remains `"captured"`.

**§5 — Semantics: change required.**

Replace:

> `available_amount` = remainder − held

With:

> `available_amount` is zero for expired credits and debit transactions; otherwise it is `remaining_amount − held_amount`. These transaction readers account for expiry and coverage only. Wallet reservations and unbacked debt are enforced at wallet level and are not apportioned among individual credits.

Otherwise, an expired credit with 100 unallocated units reports `held_amount == 0` and `available_amount == 100`.

**§6 — Operations: changes required.**

In the opening paragraph, replace:

> callbacks registered for delivery after the outermost commit.

With:

> Success callbacks are registered for delivery after the outermost commit. `insufficient_balance` remains immediate, fires once per rejected funding attempt, and does not depend on a later commit.

In §6.3, replace:

> A wallet on hold has `balance == −N`, so a new reservation fails like a debit would.

With:

> Under a wallet coverage hold, `balance == −R − N`. With overdrafts disabled, a positive new reservation is rejected; with overdrafts enabled, reservation creation remains permitted.

In §6.5, replace:

> reload and validate the reservation (active, not captured); sample `now`;

With:

> reload the reservation; sample `now` after the required wallet locks are held; validate that it is a reservation and is active and uncaptured at that same `now`;

The deadline check must use the operation’s evaluation instant.

Also replace:

> with overdrafts on, an underfunded capture becomes unbacked debt

With:

> With overdrafts enabled, capture may proceed despite insufficient available funding. It consumes eligible credits first. This can leave other reservations underfunded; only the portion exceeding eligible credit remainder becomes unbacked debt.

For example, with 100 in credits and two reservations of 80, capturing either reservation for 80 leaves 20 in credits, an outstanding reservation of 80, available −60, and **no unbacked debit**. Insufficient availability and insufficient credit buckets are different conditions.

Finally, replace:

> a failed capture rolls back completely and the reservation stays active and capturable.

With:

> A failed capture rolls back all persisted changes. The reservation remains capturable if it is still active when a later attempt acquires the wallet lock.

A rollback cannot prevent its deadline from passing.

**§7 — API reference: OK.**

**§8 — Embedding: change required.**

Replace:

> `HasMetadata` for both JSON columns

With:

> `HasMetadata` for creation metadata, plus equivalent handling for `release_metadata`: indifferent access, nil normalization, persistence of in-place changes, and cache invalidation on reload.

The existing concern hard-codes `metadata`; including it does not implement those behaviors for a second column. This matters immediately on MySQL, where the new column has no object default.

Add:

> With holds disabled, `held_balance` returns zero, `on_hold?` returns false, and `available_balance` and `total_balance` delegate to the existing dynamic `balance` implementation without hold SQL. Opted-in embedders with custom balance policies must define coherent available, held, and total readers; overriding `current_balance` alone must not accidentally violate the stated balance identity.

That preserves `usage_credits`’ custom view when it broadens its dependency without enabling holds.

**§9 — Generators and upgrade: change required.**

Replace:

> emits `add_wallets_holds` for 0.1/0.2 installs

With:

> emits `add_wallets_holds` for existing 0.1, 0.2, and 0.3 installations. Foreign-key column types match the existing referenced tables, rather than assuming the application’s current generator settings match its historical schema. Repeated generator invocation does not emit duplicate migrations.

Add the normal **0.3 → 0.4** upgrade path to the tests. That will be the immediate upgrade path under D15.

**§10 — Callbacks and initializer: addition required.**

Append:

> Each successful mutation evaluates low-balance and depleted crossings once, using its original and final available balances. This includes coverage creation, reservation creation, and targeted debits. Composite credit and capture operations do not evaluate intermediate states. Deadline passage emits no threshold callbacks. Idempotent no-ops emit no callbacks.

Also define the metadata payload:

> `hold_created` carries creation metadata. Explicit `hold_released` carries release metadata. Capture attribution is available through the context’s linked debit transaction.

**§11 — Acceptance tests: additions required.**

Add these cases:

- Expired credits report zero `available_amount`, whether previously covered or uncovered.
- Coverage rows reject capture links; captures reject foreign-wallet or invalid debit links.
- Wallet destruction proves holds are removed before inherited transaction dependencies; retained capture links are not nullified.
- With overdrafts enabled, capture funded by credit buckets but underfunded relative to other reservations creates **zero** unbacked amount.
- With overdrafts enabled, a capture exceeding eligible credit buckets creates exactly the residual unbacked amount.
- Reservation/coverage creation fires threshold callbacks once on a real crossing; overlapping reasons do not repeat the crossing.
- Failed captures and transfers emit no success callbacks even when the caller rescues and commits its surrounding transaction; funding failures still emit the immediate failure callback.
- Disabled embedded readers preserve an overridden balance policy without hold queries.
- Both JSON columns handle nil, reload, and in-place changes correctly.
- Upgrade from 0.3, including existing key types that differ from current generator settings.

Replace:

> capture vs release and capture vs capture races … (one winner, one callback)

With:

> Capture versus release and capture versus capture serialize to one terminal transition. Assert the appropriate event set: successful capture emits one `debited` and one `hold_released`; successful explicit release emits one `hold_released`; losing attempts emit no success events.

**§12 — Implementation sequence: OK**, incorporating the corrections above.

**§13 — Follow-ups: OK.** Deferring inbound transfer holds is acceptable. Document the first-release limitation clearly: `transfer_to` cannot yet issue recipient credits under an atomic initial hold.

## Gaps

These rules should be added explicitly:

1. **Failure diagnostics during capture.** Failure context must retain the original wallet balance as `previous_balance` and `new_balance`. Diagnostics must separately identify the funding available after excluding the captured reservation. Otherwise, a failed capture can either report a fictitious intermediate balance or incorrectly say no funding existed.

2. **Authoritative reads include every accounting term.** State explicitly that mutation-time reads of credits, allocations, unbacked debt, coverage, and reservations require current-read semantics. Locking the wallet and then running ordinary snapshot aggregates is insufficient under the MySQL scenario already identified.

3. **Balance identity requires a consistent read.** One evaluation timestamp does not guarantee one database snapshot across several queries. Each calculation must derive its components consistently. Separate public reader calls may observe intervening mutations; the identity is guaranteed for the same snapshot and instant.

4. **Capability errors on composite credit.** A disabled ledger must reject `credit(..., hold:)` and `credit(..., available_at:)` before creating any credit, including when `available_at:` has already passed.

5. **Real held-credit/debit race.** Add a concurrent hold-versus-debit test on PostgreSQL and MySQL: if the hold wins, ordinary spending excludes that credit; if spending exhausts the credit first, hold creation fails cleanly. Neither ordering may leave partial writes.

6. **Historical transfer behavior change.** Test the actual-unbacked fallback with pre-existing debt and later credits, even without holds. A transfer can exceed net available balance while remaining fully allocated. Under the agreed rule, that transfer now preserves expiry. Document this behavior change in the changelog.

## Nits

- Change “exactly like a bank account” to “using the familiar available/current balance distinction.” Capture here remains conditional on funding.
- D1’s “no downstream change” should say “existing available-balance gates continue to work.” Presentation, analytics, and cached-balance checks still need adoption work.
- D14’s “No aliases” should say “No additional naming aliases”; §7 intentionally includes `available_balance`.
- Change “Rows are never deleted through the supported API” to “Hold commands retain rows; owner/wallet destruction follows the cascade contract above.”

VERDICT: CHANGES