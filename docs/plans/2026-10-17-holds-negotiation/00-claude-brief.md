# Design negotiation: holds (provisional / pending value) for the `wallets` gem

You are **Astra**, co-architect on this design. The other architect is Claude. The gem owner has asked the two of us to **negotiate the solution shape until we both agree**, then Claude writes the plan and you sign it off. This document is round 1: the full context plus Claude's opening proposal. Challenge it hard where it deserves it, agree where it is right, and propose better where you can. We are optimising for the best possible gem, not for either of us being right.

## How we work on gems (owner's words, verbatim)

> To get in the right context, we're one of the best, if not the best, worldwide Ruby gem factories. Our gems are wildly known and praised in the Rails community, and millions of Ruby on Rails developers end up onboarding and using our gems over time. We're known to keep our work to the highest standards possible, and we always push, push, push for even better quality work. Better gems, more useful, more polished interface, more delightful. We're known to push the boundaries of what a "hidden gem" in Ruby means. We aim for the stars and nothing less.
>
> We're aiming at creating a world-class Ruby gem here. Only the top 0.001% work is acceptable. We must keep our code up to the highest standards of quality, we absolutely must follow the best Ruby and Rails best practices, and write our code as idiomatic (Ruby-esque, Rails-y) as humanly possible.
>
> We are suckers for syntactic sugar. Everything should read like plain English. Everything should be delightful and beautiful. A kid should be able to read key developer-facing parts of the code and just understand it. If that's not the case, we need to simplify things: make the interface & code simpler for the users of the gem to understand what the gem does, and how to use it, in a simple glance. While keeping things working, of course. Our gems "just work". All of the time. We work hard to remove the complexity from the user's cognitive load, but we do so by deeply understanding the problem at hand and coming up with extremely creative, robust, straightforward solutions that work for 100% of the use cases and feel like magic.
>
> We need to provide an absolutely delightful DX (Developer Experience). The gem onboarding, installation, usage, architecture, design... everything should be absolutely delightful and intuitive for users. The intended usage should be extremely delightful through syntactic sugar – to the point it reads like plain English and a kid could understand what it does.
>
> A general rule of thumb we should follow is: the best part is no part: if you can simplify something, simplify it. Or if you can improve the model / overall architecture while keeping everything simple. Do not overengineer or overcomplicate things. The most straightforward solution is often the best solution. Follow an SpaceX / Elon Musk strategy: simplify until the thing does its job while being p99.999. Keep things simple, keep overhead small, but this gem still has to 1000% get the job done a be a top 0.001% gem that millions of Ruby on Rails developers will use.
>
> Everything should be as simple and easy to understand and use as humanly possible. We create Ruby code like DHH himself would. Other Ruby developers looking at the gem interface / usage examples should go like: "wow! That is genius!". We're absolutely aiming for the best conceivable quality and genius.
>
> This gem will be used by millions of Ruby developers worldwide. It's extremely important we get this right. This gem will be thoroughly examined and adopted by the absolute top and best programmers in the Ruby & Rails community (dhh, excid3, ankane, tobi...) We need to delight THEM. We need to impress them.

## Read the code first

You are running inside `~/GitHub/wallets` (read-only). Read, in this order:

- `lib/wallets/models/wallet.rb` (balance math at ~170-176 and ~580-606, `allocate_debit!` ~472-502, `apply_credit`/`apply_debit`, `transfer_to`, the embeddability hooks at the top)
- `lib/wallets/models/transaction.rb`, `allocation.rb`, `transfer.rb`
- `lib/wallets/configuration.rb`, `lib/wallets/callback_context.rb`, `lib/wallets/callback_dispatcher.rb`
- `lib/wallets/models/concerns/embeddable.rb`, `has_wallets.rb`
- `lib/generators/wallets/templates/create_wallets_tables.rb.erb`
- `README.md` (API sections, "Negative balances and overdraft", "When NOT to use", "Embedding", "TODO")
- `CHANGELOG.md` top (0.3.0 is **unreleased**; rubygems latest is 0.2.0 with ~3.9k downloads)
- `test/test_helper.rb`, `test/integration/embeddability_test.rb` (the embedding contract), `.github/workflows/test.yml` (CI: SQLite, PostgreSQL, MySQL; Ruby 3.2–4.0; Rails 7.2 and 8.1)

The main embedder is `usage_credits` at `/Users/javi/GitHub/usage_credits` (read `lib/usage_credits/models/wallet.rb`): it subclasses `Wallets::WalletBase`, pins `wallets ~> 0.3.0`, and **overrides `current_balance` using the private helpers `positive_remaining_balance` and `unbacked_negative_balance(scope)`**, so those two signatures are a de facto contract.

Optional CarHey context (the first production consumer), read-only at a read-only checkout of the CarHey repo at `origin/main` (2026-10-17): `config/initializers/wallets.rb`, `app/services/payouts/request_withdrawal.rb` (debits `wallet.balance` under lock), `app/services/fraud/payout_hold.rb`, `app/services/energy_savings/earning_reversal.rb`, `app/services/referrals/reclaim_rewards.rb`, `app/models/ride.rb` (`reward_held_for_review?`).

## The problem

Apps need value that **exists in the ledger but is not yet spendable**:

- **Fraud / compliance freeze (CarHey, now):** a reward was credited; fraud detection later says "do not let this leave until the ministry pays us for that ride (3–4 months) or an operator clears it". Must work per credit, per set of credits, and for the whole wallet. Must be reversible (release) and auditable (who, why, when).
- **Pending / clearing balances:** marketplace seller earnings unavailable until the return window closes; gig earnings pending until the payout cycle; loyalty points pending until the order is non-refundable. Stripe calls this `pending` vs `available`.
- **Vesting:** referral bonus that unlocks after N days or after an event.
- **Dispute holds:** one specific credit held while a dispute runs.

What exists today in the gem: nothing. `balance` counts every non-expired credit; `allocate_debit!` consumes any non-expired credit FEFO; there is no wallet state. The README lists "escrow, pending, available, reserved, delayed-release states" under *use something else* and keeps "pending/held balance primitives" in TODO.

Every workaround fails: not crediting at all hides the money from the user and cannot be applied retroactively; a metadata flag enforced in the app leaves `balance` lying and every debit path still consumes the flagged credit; parking value in an escrow wallet and back prints two rows in the user's feed and corrupts "total earned" sums.

What the CarHey support inbox says (45 latest tickets, 12–17 Oct 2026, no PII): ~15 proactive notices from support telling users "withdrawals may be restricted until your rides are validated by the CAE authorities" with no product mechanism behind the sentence; 3 complaints that money shown as validated was then held at withdrawal time; 1 user asked to freeze the one bad ride instead of the whole wallet, and support replied that the current policy freezes everything. A visible, per-credit "held" state answers all three.

CarHey's current levers are all "block the action" (`Fraud::PayoutHold`, a blocking reason in the withdrawal checker) or "claw back" (`EarningReversal`, `ReclaimRewards` via a `:reversal` transfer), or "do not credit yet" (`Ride#reward_held_for_review?`). None is "present but unavailable". A hard lesson in that codebase (2026-08-20 outage): gate the ACTION, never hide the EXPLANATION. A hold is the explanation-friendly primitive; action gates stay in the app.

## Claude's opening proposal

### One primitive: a hold

```
wallets_holds
  wallet_id        not null
  transaction_id   nullable   -- set: hold on one credit; nil: the whole wallet is on hold
  amount           nullable   -- credit hold: required, <= that credit's unheld remainder
                              -- wallet hold: nil (everything). Column shape leaves room for
                              -- amount-based wallet reservations later (escrow pre-auth)
  category         not null   -- business meaning: pending_validation, fraud_review, vesting, dispute...
  releases_at      nullable   -- automatic release moment; nil = until released by code
  released_at      nullable
  release_reason   nullable
  metadata         json/jsonb
  timestamps
```

Active while `released_at IS NULL AND (releases_at IS NULL OR releases_at > now)`. Rows are never deleted. This mirrors `expires_at`, which the balance math already knows how to treat.

### Balance semantics (the decision that matters)

- `balance` keeps its name and becomes the **available** balance. Held value is excluded exactly the way expired value is excluded today. With no holds, nothing changes. This is what makes `has_enough_balance?`, `debit`, `transfer_to` and every host app's `wallet.balance` check respect holds with zero downstream code.
- New readers: `held_balance`, `total_balance` (available + held), `available_balance` (explicit alias), per transaction `held_amount` / `available_amount` / `held?`.
- Math: P = positive remaining (non-expired credits minus allocations), N = unbacked negative. Hc = Σ per non-expired credit of min(active hold amounts, remaining). `held_balance = on_hold? ? P : Hc`; `balance = P − held_balance − N`; `total_balance = P − N`.
- `allocate_debit!` skips the held portion of each credit. A wallet on hold refuses debits and outbound transfers with a new `Wallets::WalletOnHold < Wallets::Error`; inbound credits always land. Partial holds just lower the available balance, so the existing `InsufficientBalance` path applies; with `allow_negative_balance` a debit goes unbacked rather than touching held value.
- A held credit that expires is gone (holding does not pause expiry); documented, not solved.

### API sketch

```ruby
wallet.credit(751, category: :reward, hold: { category: :pending_validation, metadata: { ride_id: } })
wallet.credit(500, category: :referral_reward, available_at: 14.days.from_now)   # sugar: time-released hold
wallet.hold(credit_transaction, amount: nil, category: :fraud_review, releases_at: nil, metadata: {})
wallet.hold(category: :fraud_review)            # no transaction: the whole wallet is on hold
hold.release!(reason: "cae_settled")
wallet.release_holds!(category: :fraud_review, reason: "cleared_by_operator")
wallet.on_hold?  wallet.held_balance  wallet.total_balance  transaction.held?
```

Naming traps avoided on purpose: `frozen?`/`freeze!` collide with `Object#frozen?` and Active Record's own use of it; `lock!` is Active Record's row lock. Hence `on_hold?`.

### Plumbing

- `Wallets::HoldBase` (abstract) + `Wallets::Hold`, `hold_class_name` class_attribute on `WalletBase`, `table_suffix = "holds"`, `Transaction has_many :holds`. Embedders opt in like they do for transactions; a ledger without a holds table must not break (explicit `holds_enabled`-style switch or equivalent).
- Callbacks `:balance_held` and `:hold_released` through the existing `callback_event_map` (embedders can `nil` them); `CallbackContext` gains `:hold`. Success callbacks after commit like the others.
- Holds and releases run under the wallet lock and refresh the cached `balance` column; a hold stores available-before/after in its metadata like transaction snapshots.
- Time-based releases need no sweeper for correctness (computed like expiry); an optional `Wallets::Hold.release_due!` exists for apps that want the `hold_released` callback to fire for lapsed holds.
- Generators: add the table to the install template for fresh installs; a new upgrade generator for 0.1/0.2 installs. Tests run both, on all three databases.
- Out of scope for this cut: amount-based wallet reservations (escrow pre-auth). Without pinning buckets, expiry can eat a reserved amount. The column shape leaves room.
- Release plan: ship 0.3.0 as it stands (already large, dogfooded by usage_credits), holds in 0.4.0 with its upgrade migration.

## Questions I want your position on

1. **Is `balance` = available the right call**, or should `balance` stay total and a new `available_balance` become the gate? Argue it from the point of view of a downstream app upgrading, and from DHH's. (Claude's view: expired value is already excluded from `balance`, so "balance means spendable" is the existing contract; a balance you cannot spend is the trap the CarHey tickets describe.)
2. **Table vs columns.** Would `available_at` on transactions (mirror of `expires_at`) cover enough of the use cases that a table is overengineering? (Claude's view: it covers time-release only; manual holds, partial holds, wallet-wide holds and the audit trail need rows.)
3. **Is a wallet-scoped hold the same concept as a credit-scoped hold**, or should the whole-wallet case be a separate, simpler thing (a flag/state on the wallet) and the hold table stay credit-only? Think about SQL simplicity, embedders, and how it reads.
4. **Amount nullability and capping** at creation vs computed caps.
5. **Sugar.** Propose the most Ruby-esque, Rails-y reading interface you can. Ideas to react to: `wallet.credit(100, available_at: ...)`, `wallet.credit(100, held: :pending_validation)`, `wallet.credit(100).hold(...)`, `wallet.hold(txn, until: 3.months.from_now)`, `wallet.holds.release_all(reason:)`, `wallet.holds.active`, `held_balance` vs `pending_balance`. What would make dhh/excid3/ankane smile?
6. **Interplay with `allow_negative_balance`**: should a debit on a wallet whose available is insufficient but whose held value would cover it go unbacked-negative (Claude's proposal) or raise? And should a wallet on hold allow system-initiated reversals through some explicit door, or must the app release first?
7. **Interplay with expiry**: hold does not pause expiry (proposal). Agree?
8. **Embedders and upgrades**: opt-in switch vs table-existence detection vs hard requirement with a loud error. What does usage_credits need to not break on upgrade?
9. **Anything that makes this smaller.** Where is the "best part is no part"? Where is it overengineered? Where is it under-engineered for p99.999 correctness (locking, races between hold creation and a concurrent debit, PostgreSQL savepoints, MySQL JSON)?

## Protocol

Reply in markdown with these sections, in this order:

1. `## Agreements` — what you accept as is.
2. `## Disagreements` — each with the reason and what you propose instead.
3. `## Counter-proposal` — your full shape (schema, semantics, API with code samples, plumbing). Keep every code sample runnable-looking Ruby.
4. `## Open questions` — things that need the owner or more evidence.
5. End with exactly one line: `VERDICT: AGREE` if you would sign Claude's shape as written (possibly with nits listed under Agreements), or `VERDICT: CONTINUE` if the shape must change.

Write the whole reply to your final message (it is captured to a file). Be concrete, be opinionated, be brief where you agree and thorough where you disagree.
