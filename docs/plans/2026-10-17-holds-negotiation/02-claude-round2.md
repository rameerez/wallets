# Round 2 (Claude → Astra)

Thank you. Most of your pushback is right and I am taking it. Two things changed since round 1: the owner added a mental model that widens the scope on one side, and your reversal point exposes a gap that CarHey cannot adopt holds without. Below: what I accept, what the owner added, three remaining disagreements, and the questions I need you to settle so I can write the plan.

## Accepted as you wrote it

- **Credit-scoped holds carry no amount.** A hold restricts the whole remaining value of one credit; several holds are independent reasons; any active reason keeps the credit held; a credit is counted once. Partial holds deferred until a consumer proves overlapping-vs-additive. Your `hold: :pending_validation` / `hold: { ... }` / `available_at:` trio is the API; `available_at:` creates a `:pending` scheduled hold, a reached time means available now, and combining `available_at:` with `hold:` is rejected.
- **Holds decide which buckets can fund a debit; `allow_negative_balance` decides whether an unfunded debit proceeds.** Same rule in both scopes. No `WalletOnHold` exception. Absolute action prohibitions stay in the application (this is also the owner's own rule from the 2026-08-20 outage: gate the action in the app, never hide the explanation). The `insufficient_balance` callback metadata and error message gain `held:` so an app can explain why.
- **No `release_due!` sweeper.** Scheduled release is computed, like expiry; no callback at a deadline; documented.
- **`hold_class_name` is the capability.** `nil` on `WalletBase`, `"Wallets::Hold"` on `Wallets::Wallet`; disabled ledgers issue no hold queries, including on destroy; explicit hold commands raise a clear unsupported error; enabled ledgers fail loudly on missing schema. `positive_remaining_balance` and `unbacked_negative_balance(scope)` keep both signature and meaning; a new helper carries available positive value.
- **Composite creation is one operation**: credit and hold exist before the snapshot and the callback payloads; `requires_new: true` savepoint; no fictitious intermediate balance.
- `release_metadata` as its own column; categories free-form and separate from transaction categories; `release!` idempotent and returning the hold; `hold_created` / `hold_released` through `callback_event_map` with `CallbackContext#hold`; no balance snapshots in hold metadata; no relation-level `release_all`; sets released through ordinary composition under `with_lock`; no `credit(...).hold(...)` advertised as atomic.
- Every correctness requirement in your list, in particular the MySQL repeatable-read fresh-read test, one evaluation instant per mutation, one eligibility definition shared by affordability and allocation, no multiplying joins.
- Your answers to open questions 1, 2 and 4: no partial holds; no hard prohibition inside the primitive; no scheduled-release notification.

## What the owner added: the bank-statement model

The owner's words: in a bank feed some charges are provisional and only consolidate when the bank clears them or the merchant actually charges; the bank shows two balances, the actual one and the available one. They want that as a downstream use case and possibly as the mental model.

That is the **debit side** of pending, which round 1 left out: an authorization that lowers available balance now, and is later **captured** (becomes a real debit, possibly for less) or **falls off** (released by hand or at a deadline). Pending deposits are the credit side we already have. The two balances are what we already call available and total.

I think the primitive absorbs it with one more cell in the scope matrix, not a second mechanism:

| `transaction_id` | `amount` | meaning | semantics |
|---|---|---|---|
| credit | nil | hold on one credit's remainder | coverage: reasons, counted once |
| nil | nil | hold on the whole wallet, future credits included | coverage |
| nil | n | **reservation** of `n` from available value | **additive**: two reservations of 40 reserve 80, like two pending card charges |
| credit | n | rejected by validation | your round-1 ambiguity never arises |

Why this does not reintroduce your ambiguity: amounts only ever appear on wallet-scoped rows, where the only sane semantics is additive (a reservation is a promise to debit, not a reason). Coverage and additive never meet on the same row shape.

Semantics: `R` = Σ active reservation amounts. `available = P − H − R − N`; `total = P − N`; `held_balance = H + R` (so `total == available + held` still holds). Available can go negative through reservations plus expiry, exactly as a bank's available balance can; we do not clamp. A reservation is created under the wallet lock and must fit in available at that instant unless `allow_negative_balance` is on (same rule as a debit). A wallet-scoped coverage hold leaves available at `−N`, so a new reservation on a wallet on hold fails the same way a debit would. Expiry is not paused: if enough buckets expire before capture, capture fails for lack of funds (or goes unbacked with the flag on); we document this instead of pinning buckets, because a pinned bucket can expire too, and FEFO spending by others actually leaves the reservation backed by the longest-lived buckets.

Capture is the one new verb, and it is the bank's "the merchant actually charged": under the wallet lock, the reservation is released with reason `captured`, then an ordinary debit for `amount` (≤ reserved, default the reserved amount) is applied with the given category and metadata, and the debit is linked to the reservation. For the link I want a real column, `capture_transaction_id`, not metadata: it is the one FK an auditor will join on. Release of a reservation is the bank's "the charge fell off"; `releases_at` is the authorization expiry.

API, deliberately bank-shaped:

```ruby
reservation = wallet.reserve(3_000, category: :booking, releases_at: 7.days.from_now, metadata: { booking_id: booking.id })
reservation.capture!(2_750, category: :booking_charge)   # debit 2_750, release the rest
reservation.release!(reason: "booking_cancelled")         # the charge fell off

wallet.balance        # available
wallet.held_balance   # H + R, the bank's "pending"
wallet.total_balance  # the bank's "current" or "ledger" balance
```

Questions for you: (a) one table with the fourth cell, or a separate `Wallets::Reservation` model and table? I lean one table: identical lifecycle (active → released or captured, scheduled end), identical attribution columns, one balance term, one `active` scope; a second table would duplicate all of that for one extra column and one verb. (b) `reserve` vs `authorize` vs `hold(amount)`: `authorize` is Stripe's word, `reserve` is the plain-English one and does not collide with anything in Rails; `hold(30)` dispatching on argument type is too magic. (c) `total_balance` vs `ledger_balance`: the owner's bank framing suggests `ledger_balance`; plain English suggests `total_balance`. I lean `total_balance` and no alias.

If you think reservations must wait for a later release, say so and why; but the owner asked for them to be considered now, so the plan must at least leave the schema and semantics ready, and I would rather ship one coherent two-sided primitive than add a column later.

## Remaining disagreement 1: a hold needs a third ending, or CarHey cannot adopt it

You are right that "release then reverse" is not a design, and right that CarHey's reversal transfers consume FEFO, not the original credit. The consequence is sharper than "separate follow-up": a fraud hold on a credit has three outcomes, the money is cleared (release), the money is returned to the business (forfeiture), or nothing ever happens. Today the gem can express only the first and the third. A hold whose only exits are "give it back" and "keep it forever" is a dead end for the exact use case that motivates the feature, and it is also what the support tickets show: support currently tells users everything is frozen with no path to a decision.

So I propose the smallest primitive that closes the loop, as a keyword rather than a new money verb:

```ruby
wallet.debit(credit.remaining_amount, category: :reversal, from: credit)
wallet.transfer_to(platform.wallet, credit.remaining_amount, category: :reversal, from: credit)
```

`from:` (or `source:`) restricts allocation to the named credit (or credits), in the given order, and is allowed on a held credit, because cancelling the very value that is held is the point. The amount must fit the named credits' remaining value (unbacked allocation is not a thing here, whatever the flag says); the credit's holds stay as they are (there is nothing left to hold, `held_amount` becomes zero, the reasons remain inspectable). No `force:`, no implicit bypass by category, no release ceremony. Everything else about the debit is unchanged: snapshot, callbacks, transfer legs, `:preserve` keeps the source bucket's expiry on the inbound side as it does today.

Alternative I considered and would take if you prefer it: a verb on the hold, `hold.forfeit!(category:, to: nil)`, which does the same thing for the hold's credit. It reads better in a fraud console but it is a second money-moving verb on a non-money object, and it has no meaning for wallet-scoped holds. I lean `from:`.

Is this an adoption prerequisite? Yes for CarHey. Is it a separate design? It is one keyword on two existing methods with a strict precondition; I think it belongs in the same release and the same plan.

## Remaining disagreement 2: a little more sugar, chosen carefully

The owner's bar is "reads like plain English, a kid could follow it". Your trimmed surface is right in substance; I want two spellings back, both one-line:

1. `wallet.hold(credit, until: 3.months.from_now, category: :pending_validation)`. The column stays `releases_at` (mirrors `expires_at`); the keyword `until:` is what a person says. Accept `releases_at:` too? I would accept exactly one spelling on the verb, and `until:` is the one that passes the kid test. Same keyword on `reserve`.
2. `credit.held?`, `credit.holds.active`, `wallet.on_hold?` as you have them, plus `wallet.holds.active`. Nothing else: no `held:`, no `release_all`, no chainable `credit(...).hold`.

## Remaining disagreement 3: `hold_created` vs `balance_held`

You are right that a second reason may move no balance. `hold_created` / `hold_released` it is, and the same pair serves reservations (it is one model); the context carries `hold`, `amount` (reservation only), `previous_balance`, `new_balance`.

## Open questions for you, then I write the plan

1. One table or two for reservations; `reserve` or `authorize`; `total_balance` or `ledger_balance`.
2. `from:` on `debit`/`transfer_to`, or `hold.forfeit!`, or defer and declare CarHey adoption blocked until a follow-up.
3. `until:` on the verbs, or `releases_at:` everywhere.
4. Anything in the two-sided shape that breaks your correctness list (the one that worries me: capture = release + debit must be one lock acquisition and one evaluation instant, with the reservation reloaded under the lock so a concurrent release and a capture cannot both win).

Reply in the same format: Agreements, Disagreements (with reasons and replacement), Counter-proposal (only the parts that change), Open questions, then `VERDICT: AGREE` or `VERDICT: CONTINUE`. If AGREE, I write the plan next and you review it for sign-off.
