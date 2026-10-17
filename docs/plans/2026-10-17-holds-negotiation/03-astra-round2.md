## Agreements

**Reservations belong in this release now that the owner has explicitly added the debit side of pending value.** The two-sided model is useful and coherent. It does introduce obligations beyond credit holds, so the plan must settle the accounting rules below.

My answers on shape and naming:

- **One table, one model, no STI.** The nullable amount distinguishes coverage holds from additive reservations. Add explicit scopes and predicates so that distinction is visible in code.
- **`reserve`.** It describes the ledger operation directly. `authorize` suggests a payment authorization or permission decision the gem does not perform.
- **`total_balance`, without an alias.** It pairs naturally with available and held.
- **`from:` on `debit` and `transfer_to`, in this release.** Source-specific cancellation is an adoption prerequisite for CarHey. Existing allocations already provide the durable source link; a second money-moving API on holds would add less value.
- **A real `capture_transaction_id`.** The reservation must identify the debit that captured it.
- **`hold_created` / `hold_released` for both shapes.**
- **`until:` on the public commands.** I accept the sugar. Use it consistently inside `hold: { ... }` too; keep `releases_at` as the persisted attribute and reader. This API is unshipped, so we can choose one spelling cleanly.

I also accept your reservation formula and the decision that reservations can become underfunded through expiry. These are reservations against the wallet’s evolving available value, with capture subject to funding at capture time. They are not a guarantee that funds will remain available.

## Disagreements

**1. Signed available balances require changing the existing validation contract.**

Currently `refresh_cached_balance!` saves the wallet, and the model rejects a negative cached balance when overdrafts are disabled.

Your expanded formula permits negative availability without any overdraft:

1. Credit 100.
2. Reserve 80. Available is 20.
3. Place the credit under fraud review.
4. `P = 100`, `H = 100`, `R = 80`: available is **−80**.

The fraud hold must succeed. Rejecting it because an authorization already exists would be a serious failure.

Expiry creates the same problem. After availability becomes negative, even an incoming credit that improves it could fail during the cache refresh.

**Replacement:** the cached available balance validates as a signed integer. Spending and reservation commands enforce their funding policies under lock. Remove the unconditional nonnegative validation on that cache; do not substitute another blanket save-time floor that can prevent releases, incoming credits, or other repairs.

Clarify the configuration contract:

> `allow_negative_balance` permits commands to exceed available funding. Disabling it does not guarantee that available balance can never become negative through expiry or new restrictions.

This is a necessary design change, not an implementation detail.

**2. `from:` cannot bypass every available-balance constraint merely because its source is explicit.**

This example exposes the missing rule:

1. Credit A has 100.
2. Reserve 100. Available is zero.
3. Debit 100 with `from: credit_a`.

The source has enough remaining value, but consuming it would leave an outstanding reservation with no backing. Your proposed source-only precondition permits that even with overdrafts disabled.

**Replacement:** `from:` may consume coverage-held value, while respecting reservations and existing debt.

For a targeted debit:

- `D` is the requested amount.
- `C` is the portion of that debit allocated from credits currently covered by a credit or wallet coverage hold.
- `A` is available balance before the operation.

Its resulting availability is:

```ruby
available_after = available_before - amount + covered_amount_consumed
```

With overdrafts disabled, require:

```ruby
amount - covered_amount_consumed <= [available_before, 0].max
```

This gives the intended outcomes:

- Cancelling a fully held credit succeeds even when available is zero.
- Cancelling held value does not deepen an existing availability deficit.
- Selecting an ordinary unheld credit does not bypass outstanding reservations.
- With overdrafts enabled, selected credits can be consumed despite insufficient availability.
- **Every targeted debit remains fully allocated to its named sources, regardless of the flag.**

Coverage-held value and reserved value are different terms. `from:` explicitly permits consuming the former; it must not accidentally bypass the latter’s funding policy.

**3. Targeted sources must be unexpired.**

`remaining_amount` includes unallocated value even after a credit expires. That is insufficient for this operation.

Allocating a debit against an already-expired credit would consume a bucket that no longer contributes to `P`. Because the debit would be fully allocated, it would add nothing to `N` either. The sender’s total would not decrease, yet a transfer could credit the recipient.

**Replacement:** every selected source must be a persisted, unexpired credit in this wallet’s configured ledger, checked at the operation’s evaluation instant. Insufficient selected remainder always fails atomically; there is no FEFO fallback and no unbacked fallback.

Reject expired sources even with `expiration_policy: :none`. Reversing an already-expired or already-spent earning remains a distinct compensating movement, governed by the ordinary debit/overdraft rules.

**4. Capture cannot expose the intermediate release in snapshots or callbacks.**

I accept release plus debit as the internal accounting steps. They cannot behave as two separately observable wallet operations.

For a wallet containing 100 with a reservation of 100:

- Before capture: available 0, total 100.
- After full capture: available 0, total 0.

A naive implementation reports release `0 → 100`, then debit `100 → 0`. That invents an available-balance crossing and can fire depleted or low-balance callbacks incorrectly.

**Replacement:** capture records one composite transition. Capture the original balance before changing the reservation, then create the debit, finalize the reservation link, refresh the cache, and produce snapshots and callback payloads from the original and final states.

A debit of 100 can therefore have available snapshots `0 → 0`. That is correct: capture converts previously reserved value into a posted debit.

**5. Capture needs explicit terminal-state and retry rules.**

A lock prevents concurrent mutation; it does not by itself define what the losing caller should receive.

**Replacement:**

- Only an active reservation can be captured.
- Capture is one-shot, for a positive integer no greater than the original reserved amount.
- A smaller capture releases the entire unused remainder.
- An expired or manually released reservation cannot subsequently be captured.
- A second capture raises a clear state error and creates nothing.
- `release!` after capture is an idempotent no-op and preserves the capture attribution.
- A failed capture rolls back completely, leaving the reservation unchanged and eligible for a later attempt while still active.

Applications can inspect `capture_transaction` to reconcile an uncertain response. We should not silently return an existing debit for a second request whose amount or category might differ.

## Counter-proposal

Only these additions and refinements change the agreed shape.

**Reservation shape**

Keep `amount` and `capture_transaction_id` on the holds table.

Enforce:

- An amount, when present, is a strictly positive integer.
- A credit-scoped row cannot have an amount.
- A capture link is permitted only on a reservation that has been explicitly ended.
- The captured transaction is a debit in the same wallet, with absolute amount no greater than the reservation.
- A capture transaction belongs to at most one reservation.

Use database checks for row-local shape, a foreign key and unique index for the capture link, and locked validation for the cross-record accounting conditions.

Expose the distinction directly:

```ruby
wallet.holds.coverage.active
wallet.holds.reservations.active

hold.reservation?
hold.capture_transaction
```

`wallet.on_hold?` checks **wallet-scoped coverage holds only**. A pending booking must not make the wallet report that it is under a blanket hold.

Keep:

```ruby
available = positive_remaining - covered_remaining - reserved - unbacked_negative
held = covered_remaining + reserved
total = positive_remaining - unbacked_negative
```

`held_balance` can exceed `total_balance`. Coverage and reservations can overlap, and expiry can remove backing. That is an intentional consequence, not a sum to cap.

**Public deadline spelling**

Use `until:` consistently for command input:

```ruby
hold = wallet.hold(
  credit,
  category: :pending_validation,
  until: 3.months.from_now
)

credit = wallet.credit(
  500,
  category: :reward,
  hold: {
    category: :vesting,
    until: 14.days.from_now
  }
)

reservation = wallet.reserve(
  3_000,
  category: :booking,
  until: 7.days.from_now,
  metadata: { booking_id: booking.id }
)
```

`available_at:` retains the agreed convenience behavior. Explicit `hold` and `reserve` commands reject a deadline that has already been reached; silently creating an inactive restriction would conceal a caller error.

**Targeted allocation**

Accept one credit or an ordered array:

```ruby
wallet.debit(
  751,
  category: :reversal,
  from: credit,
  metadata: { reason: "reward_rejected" }
)

wallet.transfer_to(
  platform.wallet,
  751,
  category: :reversal,
  from: credit
)

wallet.debit(
  150,
  category: :reversal,
  from: [first_credit, second_credit]
)
```

Arrays preserve caller order. Reject empty arrays, duplicate sources, foreign sources, debits, and expired sources. Reload authoritative state under the wallet lock.

This is explicitly a mode that can consume held value. It must be documented prominently beside `from:`, rather than appearing only in reversal examples.

Holds remain unchanged. A partial cancellation reduces their effective held amount; a complete cancellation leaves zero held value and preserves the original reasons. No `hold_released` event fires because no hold was released. The debit, category, metadata, and allocations explain the cancellation.

For transfers, determine the `:preserve` fallback from **whether the debit actually has an unbacked portion**, not simply whether its amount exceeds available balance. A targeted transfer from a fully held credit exceeds available but is fully backed, so its expiration must remain preserved.

**Capture**

```ruby
debit = reservation.capture!(
  2_750,
  category: :booking_charge,
  metadata: { booking_id: booking.id }
)

reservation.capture_transaction
```

Omitting the amount captures the original reserved amount.

Under one wallet lock and savepoint:

1. Reload and validate the reservation.
2. Sample the evaluation instant.
3. Record the operation’s original balance.
4. Exclude this reservation from outstanding reserved value.
5. Check and allocate the debit using ordinary eligible credits. Other reservations remain fully in force.
6. Finalize `released_at`, `release_reason: "captured"`, and `capture_transaction_id`.
7. Save the final cache and available-balance snapshot.
8. Register callbacks using original/final balances, for delivery after the outermost commit.

Capture does not use `from:` and does not consume coverage-held credits. A later fraud hold can therefore prevent capture. With overdrafts enabled, ordinary capture may instead produce unbacked debt.

Use the existing `transaction` field in callback context to expose the capture debit on the corresponding `hold_released` event. Capture metadata belongs on the debit; its foreign key makes attribution discoverable without duplicating that metadata.

**Additional acceptance tests**

The plan needs explicit cases for:

- Coverage placed over value already supporting reservations.
- Expiry making availability negative with overdrafts disabled.
- Incoming credits and releases succeeding in that state.
- Targeted cancellation preserving the reservation funding rule.
- Rejection of expired targeted sources under every transfer expiration policy.
- Preservation of expiry on a fully backed targeted transfer whose available balance is zero.
- Full and smaller captures, including failure without any partial release.
- Capture versus release, capture versus capture, and capture at the exact deadline.
- Capture snapshots and threshold callbacks containing no intermediate availability.
- Owner destruction with both source-credit and capture foreign keys; the new links must fit the existing deletion contract.

## Open questions

The scope and naming questions are settled from my side: **one table, `reserve`, `total_balance`, `from:`, and `until:`.**

Two accounting decisions need your agreement before the plan is ready:

1. **Signed availability:** accept that `allow_negative_balance: false` controls command funding, while expiry and new coverage restrictions may still produce negative available balances and must not make the wallet unsaveable.
2. **Targeted allocation:** accept the funding rule above, allowing consumption of coverage-held value while preventing source selection from silently defeating reservations when overdrafts are disabled.

With those corrections and the capture lifecycle specified, I would be ready to review the implementation plan.

VERDICT: CONTINUE