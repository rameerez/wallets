## Agreements

**`balance` should mean available balance.** That preserves the useful existing contract: it is the value against which ordinary spending is checked. Keeping `balance` as total would make existing withdrawal code spend pending earnings unless every application found and changed every call site.

CarHey’s withdrawal service is a concrete example: it reads `wallet.balance` and debits that amount under the wallet lock. Your proposed meaning makes that flow respect held value naturally. Applications must still update presentation to show available, held, and total; this is not literally zero downstream work.

From the Rails design perspective, the obvious method should give the answer most callers need. `wallet.balance` should remain that method.

I also agree with:

- **A hold table.** `available_at` alone cannot represent independent reasons, manual releases, wallet scope, or release attribution.
- **One model for credit and wallet scope.** Both have the same lifecycle and audit needs. A separate wallet flag would immediately need reasons, actors, timestamps, and overlapping restrictions.
- **Expiry continues normally.** A hold does not extend a credit’s lifetime. Releasing an expired credit restores nothing.
- **`held_balance`, not `pending_balance`.** Fraud and disputes are not necessarily pending approval. Applications can use “pending” as a presentation label.
- **Abstract `HoldBase`, embedded class resolution, mapped callbacks, and computed deadlines.**
- **No wallet amount reservations in this release.**
- **Ship the existing 0.3.0 work separately; target holds for 0.4.0.**

## Disagreements

**1. The proposed amount model cannot represent independent restrictions on the same credit.**

Consider:

```ruby
credit = wallet.credit(100, hold: { category: :pending_validation })
fraud_hold = wallet.hold(credit, category: :fraud_review)
```

The second hold must succeed. Validation can finish while fraud review remains open, or vice versa.

Requiring each hold’s amount to fit within the **unheld** remainder prevents that. Allowing overlapping amounts and capping their sum fixes this example but introduces a different question: are two holds of 40 restricting the same 40, or separate portions totaling 80? The schema does not answer it.

**My recommendation: omit `amount` in the first release.** A credit hold restricts its entire remaining value. Multiple holds are independent reasons; any active reason keeps the credit held.

Every stated use case works with this:

- One credit.
- A selected set of credits.
- All current and future credits in a wallet.
- Scheduled or manual release.
- Multiple independent investigations.

Partial holds are a plausible future requirement, but they are additional semantics, not free flexibility. I would add them after a concrete consumer establishes whether it needs overlapping restrictions or additive reservations.

**2. A wallet hold should not silently override `allow_negative_balance`.**

Your proposal treats these differently:

- Hold every existing credit individually: overdrafts remain possible.
- Hold the wallet: every debit fails.

The difference should be coverage of future credits, not a second debit authorization policy.

I propose:

> Holds determine which credit buckets can fund a debit. `allow_negative_balance` continues to determine whether an unfunded debit may proceed.

That applies to both scopes. Consequently, **no `WalletOnHold` exception in this release**.

With overdrafts enabled, holding 100 and debiting 30 produces:

| Reader | Value |
|---|---:|
| `balance` | -30 |
| `held_balance` | 100 |
| `total_balance` | 70 |

The debit has not consumed the held credit. It has created debt.

This distinction must be prominent in documentation: **holds do not prohibit overdrafts or replace application authorization**. CarHey already separates those responsibilities, and its withdrawal amount comes from available balance under lock.

If the owner wants an absolute prohibition on outgoing activity, that is a separate policy decision. I would not smuggle it into one scope of this primitive.

**3. “Release first” is not a sufficient reversal design.**

CarHey’s reversal services identify an original credit in metadata, but use ordinary `transfer_to`. The allocator still follows FEFO; that metadata does not select the original credit.

Releasing a disputed credit and then transferring its amount can consume unrelated credits first. Conversely, leaving it held while permitting an overdraft creates debt while the disputed credit remains present. Subsequent expiry can materially change that result.

For this release:

- Ordinary compensating debits and transfers retain the existing overdraft behavior.
- No category, including `:reversal`, implicitly bypasses holds.
- No generic `force: true` door.
- No temporary release/re-hold ceremony.
- Explicitly distinguish a compensating wallet movement from cancellation of a particular credit.

A source-specific reversal primitive deserves its own design. If CarHey requires that to adopt holds safely, it is an adoption prerequisite we must resolve, not claim that the existing transfer already supplies.

**4. Drop `release_due!` from the first release.**

Computed release and persisted release are different events:

- Value becomes available at the deadline.
- A worker might observe that hours later.
- The application might spend the value before that worker runs.

Calling the latter `hold_released` invites misleading before/after balances and timestamps. Reliable delivery would also require more than the existing callbacks, which log and swallow handler exceptions.

Keep scheduled release correct without a worker. Emit `hold_released` for an explicit state transition through `release!`. Document that reaching a deadline emits no callback, just as reaching credit expiry currently emits none.

**5. Embedding needs a concrete capability boundary.**

Do not discover accounting behavior from table existence. A missing table must not silently make held value spendable.

Use `hold_class_name` itself as the capability:

- `WalletBase`: `nil`, disabled.
- Concrete `Wallets::Wallet`: `"Wallets::Hold"`, enabled.
- An embedded wallet opts in by configuring its own hold class and associations.

Disabled ledgers must perform **no hold-table queries**, including during destruction. Explicit hold commands raise a clear unsupported-feature error.

Enabled ledgers require their migration. Missing schema fails loudly.

Also preserve both the signatures **and meanings** of `positive_remaining_balance` and `unbacked_negative_balance(scope)`. Changing the former to exclude holds would silently alter `usage_credits`’ custom accounting.

**6. Atomic creation needs more than calling the existing methods consecutively.**

This cannot be the implementation:

```ruby
credit = wallet.credit(100)
wallet.hold(credit, category: :pending_validation)
```

Besides the spending window, the existing `apply_credit` records snapshots and schedules callbacks before the hold exists.

The composite operation must create the credit and hold before its final balance snapshot and callback payloads. It also needs its own rollback boundary when called inside a transaction whose caller rescues the failure. Rails joins nested transactions by default; `requires_new: true` provides the savepoint needed here. [Rails transaction documentation](https://api.rubyonrails.org/classes/ActiveRecord/Transactions/ClassMethods.html)

## Counter-proposal

**The primitive**

A hold is an independently releasable restriction on the remaining value of one credit, or on all current and future credits in one wallet.

A hold never moves value and never creates a debit or credit.

**Schema**

| Column | Meaning |
|---|---|
| `wallet_id` | Required wallet foreign key |
| `transaction_id` | Optional credit foreign key; null means wallet scope |
| `category` | Required, nonblank business reason |
| `releases_at` | Optional scheduled end |
| `released_at` | Explicit release timestamp |
| `release_reason` | Explanation for explicit release |
| `metadata` | Creation attribution and application context |
| `release_metadata` | Release attribution and application context |
| timestamps | Creation/update timestamps |

No amount, status enum, polymorphic target, or speculative reservation fields.

Use the existing primary-key conventions, table prefixing, and adapter-aware JSON handling. Release metadata must not overwrite creation metadata. Actor identifiers belong in these JSON objects; the gem need not depend on an application’s actor model.

Add foreign keys and ordinary composite indexes supporting wallet/transaction lookup with `released_at`. Avoid PostgreSQL-only partial indexes as a correctness dependency.

A credit target must be persisted, positive, unexpired, in the configured ledger, and owned by this wallet. Reject a credit with no remaining value. An already-held credit remains a valid target.

Categories are free-form business labels, separate from transaction category configuration. Do not make category unique: two disputes can have the same category.

Creation facts are immutable through the supported API. Release is a one-way transition. No ordinary hold-deletion API. Retention on owner destruction must follow the repository’s documented lifecycle rather than promising that rows can literally never disappear.

**Semantics**

At one evaluation instant:

- `P`: remaining value in unexpired credits.
- `N`: unbacked negative value.
- `H`: remaining value in credits covered by at least one active hold.

A wallet-scoped hold covers every credit, including credits received afterward. Multiple applicable holds count a credit once.

The balances are:

```ruby
available = positive_remaining - held - unbacked_negative
total = positive_remaining - unbacked_negative
```

Thus `total_balance == balance + held_balance` for the same ledger snapshot and instant. Do not clamp available balance to zero or subtract debt from held value.

A hold is active when it has not been explicitly released and its scheduled end is absent or strictly in the future. At the exact deadline it is inactive.

For credit transactions:

- `remaining_amount` keeps its current meaning.
- `held_amount` is the unexpired remainder if an applicable hold exists, otherwise zero.
- `available_amount` is the unexpired remainder minus `held_amount`.
- `held?` means `held_amount.positive?`.
- Wallet-scoped holds affect these readers too.
- Historical reasons remain inspectable even after expiry makes `held_amount` zero.

`wallet.on_hold?` specifically means an active wallet-scoped hold exists. It can be true on an empty wallet because future credits are covered.

FEFO consumes only eligible credits. With negative balances disabled, insufficient available balance raises the existing `InsufficientBalance`. With them enabled, any unfunded portion becomes unbacked debt, regardless of hold scope.

**API**

Keep `hold:` as the single credit-creation keyword, with a symbol shorthand and a hash for details:

```ruby
credit = wallet.credit(
  751,
  category: :reward,
  hold: :pending_validation
)

credit = wallet.credit(
  751,
  category: :reward,
  hold: {
    category: :pending_validation,
    metadata: { ride_id: ride.id }
  }
)
```

Both are atomic and return the credit transaction.

Keep the particularly useful time sugar:

```ruby
credit = wallet.credit(
  500,
  category: :reward,
  available_at: 14.days.from_now
)
```

This creates a scheduled hold with category `:pending`. A time already reached means immediately available. Reject combining `available_at:` with `hold:`; callers needing a named scheduled reason use the explicit form:

```ruby
credit = wallet.credit(
  500,
  category: :reward,
  hold: {
    category: :vesting,
    releases_at: 14.days.from_now
  }
)
```

Retroactive and wallet-wide restrictions use the same command:

```ruby
fraud_hold = wallet.hold(
  credit,
  category: :fraud_review,
  metadata: {
    case_id: review_case.id,
    actor_id: operator.id
  }
)

wallet_hold = wallet.hold(
  category: :fraud_review,
  metadata: { case_id: review_case.id }
)
```

Release the specific reason that was cleared:

```ruby
fraud_hold.release!(
  reason: "cleared_by_operator",
  metadata: { actor_id: operator.id }
)
```

Releasing one hold leaves all others intact. `release!` returns the hold and is idempotent: an already inactive hold is a no-op, with no overwritten attribution or repeated callback.

Queries stay ordinary Active Record:

```ruby
wallet.holds.active
wallet.holds.where(category: :fraud_review)
credit.holds.active

wallet.balance
wallet.available_balance
wallet.held_balance
wallet.total_balance
wallet.on_hold?

credit.available_amount
credit.held_amount
credit.held?
```

Implement the explicit balance synonym with dynamic delegation:

```ruby
def available_balance
  balance
end
```

For sets, ordinary transaction composition is enough initially:

```ruby
holds = wallet.with_lock(requires_new: true) do
  wallet.transactions.where(id: credit_ids).order(:id).map do |credit|
    wallet.hold(
      credit,
      category: :fraud_review,
      metadata: { case_id: review_case.id }
    )
  end
end
```

Release the exact reviewed set atomically:

```ruby
wallet.with_lock(requires_new: true) do
  wallet.holds.where(id: reviewed_hold_ids).order(:id).each do |hold|
    hold.release!(
      reason: "cleared_by_operator",
      metadata: { actor_id: operator.id }
    )
  end
end
```

That matters for CarHey: its existing clearance logic deliberately distinguishes the evidence an operator reviewed from newer findings. A category-wide release is not an appropriate default for that workflow.

I would initially omit `held:`, `until:`, transaction mutation aliases, and relation-level `release_all`. We can add conveniences after establishing one dependable path. In particular, do not advertise `wallet.credit(100).hold(...)` as atomic pending issuance.

**Embedding and upgrade**

Add abstract `HoldBase` and concrete `Hold`, with `table_suffix = "holds"`.

Install concrete hold associations where the feature is enabled. Simply adding inherited `dependent: :destroy` associations to the abstract bases could make disabled embedded ledgers query nonexistent tables during teardown.

For `usage_credits`:

1. Its current `~> 0.3.0` dependency excludes 0.4.0; it will not accidentally receive this release.
2. Broadening that dependency must work with holds disabled and no embedded holds table.
3. Opting in later requires its own hold model, migration, associations, and deliberate changes to its balance override.
4. Preserve its refund-only debt treatment and zero-floor behavior. Do not route around `current_balance` or change the two existing helper meanings.

The base implementation can gain a separate helper for available positive value. Embedded implementations adopt that deliberately.

Fresh standalone installations get the table. Existing standalone installations run the upgrade migration before deploying code that requires it. Test upgrades from both historical schemas, custom prefixes, and supported key types. Do not rewrite already-generated application migrations.

**Callbacks and snapshots**

Use `hold_created` and `hold_released`, mapped through `callback_event_map`, with `CallbackContext#hold`.

`hold_created` is more accurate than `balance_held`: adding a second reason may change no balance at all.

For atomic held credits:

- The credit callback still reports the credited amount.
- Its available-before/after numbers describe the completed composite operation.
- There is no fictitious intermediate spendable balance.
- Success callbacks run only after the outermost commit.

Explicit mutations that cross low/depleted thresholds should use the existing crossing semantics. Adding an overlapping hold with zero additional effect does not generate another crossing.

Scheduled deadlines produce no callbacks or database writes. The persisted wallet balance remains a cache that can become stale through time, as it already can through expiry. SQL readers must not treat it as authoritative available balance.

I would not add persisted balance snapshots to hold metadata initially. Creation/release facts provide the required audit trail; callback payloads can carry operation balances.

**Correctness requirements for the plan**

- **One lock order:** wallet first, then ledger children. Transfers retain deterministic wallet-pair ordering. `hold.release!` must not lock its row before its wallet.
- **One evaluation time per mutation:** sample after obtaining the required wallet locks; use it consistently for expiry, scheduled release, eligibility, and snapshots.
- **One eligibility definition:** affordability and allocation must agree. Avoid separate Ruby and SQL interpretations of active holds.
- **No duplicated sums:** use existence predicates or separately aggregated data; joining credits directly to multiple holds and allocations will multiply amounts.
- **Fresh mutation reads:** acquiring a wallet lock does not automatically refresh earlier ordinary reads in a caller’s MySQL repeatable-read transaction. Authoritative hold and allocation reads need current-read semantics; test a transaction that reads first, waits while another transaction creates a hold, then acquires the wallet lock. [MySQL consistent-read documentation](https://dev.mysql.com/doc/refman/8.0/en/innodb-consistent-read.html)
- **Atomic failure:** failed held-credit creation must leave no credit even when the caller rescues and commits its outer transaction. Failed releases must leave no partial release batch.
- **No stale release decisions:** reload state under the wallet lock; concurrent releases produce one transition and one callback.
- **No accidental idempotency by category:** applications should persist returned hold IDs with their business operation. A retried command otherwise creates another independent reason.
- **Adapter-real tests:** exercise races on PostgreSQL/MySQL, not merely sequential SQLite tests. Include overlapping reasons, wallet-plus-credit scope, future inbound credits, exact time boundaries, expiry before release, overdrafts, preserved transfers, callback rollback, and embedded-only installations.

## Open questions

1. **Is there a present requirement to hold part of one existing credit?** None of the stated scenarios requires it. My recommendation is to defer amounts rather than choose ambiguous overlap semantics.

2. **Does “whole wallet on hold” need to forbid even explicitly permitted overdrafts?** My recommendation is consistent value eligibility across both scopes, with absolute action restrictions remaining in the application. If the owner requires a hard prohibition, we must explicitly design its interaction with reversals.

3. **Must CarHey cancel a particular held credit while other holds remain active?** Its current reversal transfers do not provide source-specific consumption. We need agreement on whether that is a prerequisite for adoption or a separate follow-up.

4. **Does any consumer need notification at scheduled release?** If yes, specify timing and delivery guarantees before adding a sweeper. Computed availability alone does not provide reliable event delivery.

VERDICT: CONTINUE