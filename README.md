# 💼 `wallets` - Add user wallets with money-like balances to your Rails app

[![Gem Version](https://badge.fury.io/rb/wallets.svg)](https://badge.fury.io/rb/wallets) [![Build Status](https://github.com/rameerez/wallets/workflows/Tests/badge.svg)](https://github.com/rameerez/wallets/actions)

> [!TIP]
> **🚀 Ship your next Rails app 10x faster!** I've built **[RailsFast](https://railsfast.com/?ref=wallets)**, a production-ready Rails boilerplate template that comes with everything you need to launch a software business in days, not weeks. Go [check it out](https://railsfast.com/?ref=wallets)!

Allow your users to have wallets with money-like balances for value holding and transferring. `wallets` gives any Rails model money-like wallets backed by an append-oriented transaction ledger. You can use these wallets to store and transfer value in any "currency" (points inside your app, call minutes, in-game resources, in-app assets, etc.)

![wallets](wallets.webp)

Use it for:

- **Rewards & loyalty points**: Cashback, points, store credit, referral bonuses
- **Marketplace balances**: Seller earnings, buyer credits, platform payouts
- **Gig economy**: Driver earnings, rider credits, tip wallets
- **Multi-currency balances**: EUR, USD, GBP wallets per user
- **Game resources**: Wood, stone, gems, gold, energy; any virtual economy
- **Telecom / SIM data plans**: "This plan gives you 10 GB per month, transfer unused data to friends"

At its core, `wallets` provides your users with: a wallet with balance, a log of transactions, expirable balances, and transfers between users.

For example, imagine you're building a SIM card app with data plans. At the beginning of each month, you give your users expirable data and call minutes:

```ruby
user.wallet(:mb).credit(10_240, expires_at: month_end)   # 10 GB in MB
user.wallet(:minutes).credit(500, expires_at: month_end) # 500 call minutes
```

Users can transfer their unused balance to friends:

```ruby
user.wallet(:mb).transfer_to(friend.wallet(:mb), 3_072)  # Send 3 GB
```

And balances decrease as they're consumed:

```ruby
user.wallet(:mb).debit(512, category: :network_usage)
user.wallet(:mb).balance  # => 6656 MB remaining
```

> [!TIP]
> If you want to implement usage credits in your app, use the [`usage_credits`](https://github.com/rameerez/usage_credits) gem! It uses `wallets` under the hood, and on top provides very handy DX ergonomics for recurring credits fulfillment, credit pack purchases, `pay` integration for charging users for credits, etc. `wallets` sits at the core of the `usage_credits` gem. It's meant to handle a generalized version of any digital in-app currency, not just credits. If you don't know whether you should use the `wallets` gem or the `usage_credits` gem, check out the [`wallets` vs `usage_credits`](#wallets-vs-usage_credits--which-gem-do-i-need) section below.

## Why this gem

`wallets` gives you more than `users.balance += 1`, but less than a full banking system:

| Feature | What it does |
|---------|--------------|
| **Multi-asset** | One wallet per asset: `user.wallet(:usd)`, `user.wallet(:gems)` |
| **Append-oriented ledger API** | Every balance change made through the wallet API creates a transaction row |
| **Expiration-aware allocation** | Debits consume soonest-expiring credits first, then the oldest bucket |
| **Holds and reservations** | Keep value pending or set aside: `balance` is what can be spent, `held_balance` what is held |
| **Linked transfers** | Both sides of a transfer are recorded and queryable |
| **Row-level locking** | Prevents race conditions and double-spending |
| **Balance snapshots** | Each transaction records before/after balance for reconciliation |
| **Rich metadata** | Attach any JSON to transactions for audit and filtering |

## Quick start

Add the gem to your Gemfile:

```ruby
gem "wallets"
```

Requires Ruby 3.2+ and Rails 7.2.3.1–8.x. Ruby 3.2 is the security floor because current patched versions of transitive Rails dependencies no longer support Ruby 3.1.

Then run:

```bash
bundle install
rails generate wallets:install
rails db:migrate
```

Add `has_wallets` to any model that should own wallets:

```ruby
class User < ApplicationRecord
  has_wallets default_asset: :coins
end
```

That gives you:

```ruby
user.wallet           # => same as user.main_wallet
user.main_wallet      # => wallet(:coins)

user.wallet(:coins).credit(100, category: :reward)
user.wallet(:coins).debit(25, category: :purchase)

user.wallet(:wood).credit(20, category: :quest_reward)
user.wallet(:gems).credit(5, category: :top_up)
```

## Example

Here is a more relatable money flow for a home-cleaning app:

```ruby
class User < ApplicationRecord
  has_wallets default_asset: :eur_cents
end

class Platform < ApplicationRecord
  has_wallets default_asset: :eur_cents
end

sara = User.find(1)      # customer
lucia = User.find(2)     # cleaner
platform = Platform.first

# Sara books a cleaning and tops up her wallet
sara.wallet.credit(10_000, category: :top_up, metadata: { source: "card" })

# Sara books a 2-hour cleaning for €60.00
booking_total = 6_000
platform_fee = 900
cleaner_payout = booking_total - platform_fee

# Sara pays the platform the gross booking price
charge = sara.wallet.transfer_to(
  platform.wallet,
  booking_total,
  category: :cleaning_booking_charge,
  metadata: { booking_id: 42, cleaner_id: lucia.id }
)

# The app later pays Lucia the net amount and keeps its fee
payout = platform.wallet.transfer_to(
  lucia.wallet,
  cleaner_payout,
  category: :cleaner_payout,
  metadata: {
    booking_id: 42,
    customer_id: sara.id,
    gross_transfer_id: charge.id,
    platform_fee: platform_fee
  }
)

# Query the linked transfer records later
charge.outbound_transaction
payout.inbound_transactions
```

Amounts are always integers. For money, store the smallest unit like cents. For games, store whole resource units.

## API

### Owners

```ruby
class User < ApplicationRecord
  has_wallets default_asset: :credits
end
```

Options:

- `default_asset:` asset returned by `user.wallet` and `user.main_wallet`
- `auto_create:` whether the main wallet should be created automatically
- `initial_balance:` optional starting balance for the auto-created main wallet

### Lookup wallets

```ruby
user.wallet            # => default asset wallet
user.main_wallet       # => same as user.wallet
user.wallet(:eur)      # => auto-creates the EUR wallet if needed
user.wallet?(:gems)    # => whether a wallet already exists
user.find_wallet(:usd) # => returns nil instead of auto-creating
```

### Credit and debit

```ruby
wallet = user.wallet(:gems)

wallet.credit(100, category: :reward)
wallet.debit(20, category: :purchase)

wallet.balance
wallet.history
wallet.has_enough_balance?(50)
```

Every transaction can carry metadata:

```ruby
wallet.credit(
  500,
  category: :top_up,
  metadata: { source: "promo_campaign", campaign_id: 12 }
)
```

### Transfers

For internal app payments, transfers are the main primitive:

```ruby
sender = user.wallet(:eur)
receiver = other_user.wallet(:eur)

transfer = sender.transfer_to(
  receiver,
  2_000,
  category: :peer_payment,
  metadata: { message: "Dinner split" }
)

transfer.outbound_transaction
transfer.inbound_transactions
```

`category:` on `transfer_to` describes the **business meaning of the transfer itself**. The ledger entries created underneath are still recorded as `transfer_out` and `transfer_in`, and the original transfer category is mirrored into transaction metadata as `transfer_category`.

That means you can query transfers directly for business flows:

```ruby
user.wallet.outgoing_transfers.where(category: :peer_payment)
user.wallet.incoming_transfers.where(category: :peer_payment)
```

Or query the ledger legs when you need transaction-level audit data:

```ruby
user.wallet.history
    .by_category(:transfer_in)
    .where("metadata->>'transfer_category' = ?", "peer_payment")
```

Transfers require both wallets to use the same asset and the same wallet class. `:eur` can move to `:eur`; `:wood` can move to `:wood`; `Wallets::Wallet` cannot transfer directly to `UsageCredits::Wallet`.

> [!NOTE]
> **Transfer expiration behavior:** Transfers preserve expiration buckets by default. If a single transfer consumes multiple source buckets with different expirations, the receiver gets multiple inbound credit transactions so those expirations remain intact.
>
> You can override that per transfer:
>
> ```ruby
> sender.transfer_to(receiver, 100, expiration_policy: :none)           # evergreen on receive
> sender.transfer_to(receiver, 100, expires_at: 30.days.from_now)       # fixed expiration on receive
> sender.transfer_to(receiver, 100, expiration_policy: :fixed, expires_at: 30.days.from_now)
> ```

### Negative balances and overdraft

By default `wallets` rejects any debit or transfer that would push a wallet below zero. Some apps (ride-fare apps with rewards, family wallets with shared spend, telecom plans with bridging credit, etc.) want to allow a small overdraft so the user experience doesn't hard-stop on a low balance.

Flip one flag and it applies consistently to `wallet.debit`, `wallet.transfer_to`, `wallet.reserve` and `reservation.capture!`:

```ruby
Wallets.configure do |config|
  config.allow_negative_balance = true
end

passenger.wallet(:eur).balance       # => 100  (1€)
passenger.wallet(:eur).transfer_to(driver.wallet(:eur), 300, category: :ride_fare)
passenger.wallet(:eur).reload.balance # => -200 (-2€)
driver.wallet(:eur).reload.balance    # => 300  (3€)
```

A few things to know:

- **Apps own the floor.** The flag is binary — it doesn't cap how negative a wallet can go. If you want a "5€ convenience overdraft", enforce that in your domain code before calling `transfer_to` (e.g. a `WalletPolicy.can_afford?(wallet:, amount:)` service that checks `wallet.balance + MAX_OVERDRAFT >= amount`).
- **`has_enough_balance?` stays strict.** It answers "does this wallet have enough on hand right now?" — overdraft is a deliberate choice the caller makes by attempting the debit/transfer, not by querying. So `wallet.has_enough_balance?(amount)` returns `false` even when the gem would happily complete an overdraft.
- **`:preserve` expiration falls back to `:none` when a transfer goes negative.** With `allow_negative_balance = true` and the default `:preserve` policy, transfers that exceed the source's positive buckets can't honestly "preserve" an expiration on the deficit portion (there is no source bucket). The transfer's `expiration_policy` is automatically downgraded to `:none` for that transfer; the receiver gets a single evergreen credit. Explicit `:fixed` (with `expires_at:`) and `:none` are honored as-is.
- **`:balance_depleted` fires on positive→non-positive crossings**, not on exact zero. A debit that takes a wallet from +100 to -50 in one shot still fires the callback. With `allow_negative_balance = false` a debit stops at exactly zero, but a hold over value that is also reserved can still take the available balance below it (see [Holds and reservations](#holds-and-reservations)), and the callback fires the same way.
- **`:low_balance_reached` is one-shot per crossing**, regardless of how deep the dip goes. Going from +200 to -100 fires once; the next debit from -100 to -200 does not re-fire because the wallet was already below threshold.
- **`:insufficient_balance` callback.** Fires only when a debit, transfer, reservation or capture is actually rejected (i.e. flag off or your service-layer floor refused). Successful overdraft transfers do not fire it.
- **Credits don't auto-settle prior debt.** If a wallet is at -50 and you `credit(80)`, the wallet's balance becomes 30 — but the unbacked -50 debit and the +80 credit persist as independent ledger rows. The next debit consumes from the +80 bucket without back-filling the older unbacked debit. The math is consistent; the audit story is "we never settled the original debt with this credit". If you want auto-settlement, do it in your service layer (e.g. when crediting, `wallet.transactions.where("amount < 0").where("ABS(amount) > spent_amount") …` and create allocations explicitly).
- **System-initiated reversals.** Refunds and payout reversals via `transfer_to` will also go through, even if the recipient's wallet ends up below zero. That's correct: the ledger has to settle, and a negative wallet records a real debt instead of a silent failure. Apps that want to *block* user-initiated overdrafts but *allow* system reversals should keep the floor check in their service layer, not toggle the flag mid-request.
- **The flag decides what commands may do, not what the balance may read.** With it off, no command may spend beyond the available balance. Yet the available balance can still read negative: when a hold covers value that is also reserved, or when reserved value expires (see [Holds and reservations](#holds-and-reservations)). Such a wallet stays saveable, takes credits and releases, and refuses new spending until it is back in funds. So turning the flag off while some wallets are negative is safe: they keep their debt and stop going deeper.
- **Concurrent writes serialize.** `wallet.debit` / `wallet.credit` use `with_lock` (row-level `SELECT … FOR UPDATE`); `wallet.transfer_to` locks both wallets in id order via `lock_wallet_pair!`. Two concurrent overdraft debits on the same wallet serialize cleanly — they don't double-count `previous_balance`.

### Expiring balances

Credits can expire:

```ruby
user.wallet(:coins).credit(
  1_000,
  category: :season_reward,
  expires_at: 30.days.from_now
)
```

Debits consume the soonest-expiring credits first, then the oldest. Expired value is never spent, and neither is held value (see [Holds and reservations](#holds-and-reservations)).

## Holds and reservations

Sometimes value is in a wallet but must not be spent yet. A reward waits for validation. A seller's earnings wait out the return window. A booking sets money aside until the service is delivered. A fraud review freezes one credit, or the whole wallet. `wallets` models all of these with **holds**, and reads them the way your bank statement does:

| On your bank statement | In `wallets` |
|---|---|
| A deposit that has not cleared | A credit under a **hold** (on that credit, or on the whole wallet) |
| A card charge that stays pending until the merchant captures it | A **reservation** of an amount, later **captured** or released |
| Available balance | `wallet.balance` (also `wallet.available_balance`) |
| Pending | `wallet.held_balance` |
| Current balance | `wallet.total_balance` |

`balance` is always what can be spent right now. Held value is left out of it, exactly the way expired value already is, and `total_balance` is always `balance + held_balance`. If you never place a hold, nothing changes: `held_balance` is `0` and `total_balance` equals `balance`.

There is one honest difference from a bank. Value in `wallets` can expire, and a hold never stops that clock. So a capture still needs funding at the moment it happens.

Hold categories are free-form labels such as `:fraud_review` or `:pending_validation`, and need no configuration. The debit categories in these examples (`:reversal`, `:booking_charge`) are ordinary transaction categories, so add them to `config.additional_categories`.

### Pending value you received

Credit the value now and let it become spendable later:

```ruby
credit = wallet.credit(751, category: :reward, hold: :pending_validation)

wallet.balance        # => 0
wallet.held_balance   # => 751
wallet.total_balance  # => 751

credit.held?                          # => true
credit.holds.active.map(&:category)   # => ["pending_validation"]
```

The credit and its hold are written in one step, so the value is never spendable in between, not even in a callback or a balance snapshot.

Pass a Hash to give the hold a deadline and its own metadata. When the deadline arrives, the value becomes available on its own:

```ruby
wallet.credit(751, category: :reward, metadata: { ride_id: 7 },
  hold: { category: :pending_validation, until: 3.months.from_now, metadata: { case_id: 42 } })
```

Or just say when the value becomes available. `available_at:` is shorthand for a hold of category `:pending` until that time:

```ruby
wallet.credit(500, category: :reward, available_at: 14.days.from_now)   # a referral bonus that unlocks in 14 days
```

A time that has already passed means available now, with no hold at all. Pass `hold:` or `available_at:`, not both.

### Holding value that already landed

Hold a credit that is already in the wallet:

```ruby
hold = wallet.hold(credit, category: :fraud_review, metadata: { case_id: 42 })
```

A credit hold always holds the credit's whole remaining value. One credit can be held for several reasons at once. Each hold is an independent reason, released on its own, and the credit stays held while any of them is active. Its value is still counted once:

```ruby
fraud   = wallet.hold(credit, category: :fraud_review)
dispute = wallet.hold(credit, category: :dispute, until: 30.days.from_now)

fraud.release!
credit.held?   # => true, the dispute still holds it

dispute.release!
credit.held?   # => false
```

Leave the credit out to hold the whole wallet. Every credit is held, including credits that arrive later:

```ruby
wallet.hold(category: :chargeback, metadata: { case_id: 7 })

wallet.on_hold?                              # => true
wallet.balance                               # => 0
wallet.credit(40, category: :reward).held?   # => true
```

Only leaving the credit out holds the whole wallet. Passing `nil` raises `ArgumentError`, so a lookup that found nothing can never freeze a wallet by accident. `on_hold?` is true only for a hold on the whole wallet: a held credit or a pending reservation does not count.

Release a hold to make its value available again. Why it ended is recorded next to why it began, never over it:

```ruby
hold.release!(reason: "cleared_by_operator", metadata: { actor_id: 12 })

hold.released?        # => true
hold.release_reason   # => "cleared_by_operator"
hold.release_metadata # => { "actor_id" => 12 }
hold.metadata         # => { "case_id" => 42 }
```

`release!` is idempotent. On a hold that has already ended (released, captured, or past its deadline) it changes nothing and reports nothing.

There is no `release_all`, on purpose: an operator clears the exact holds they reviewed, never "everything in a category". To release a set together, release each one inside one wallet lock:

```ruby
wallet.with_lock do
  reviewed_holds.each { |hold| hold.release!(reason: "cleared_by_operator") }
end
```

To find holds:

```ruby
wallet.holds.active                # every hold in force right now
wallet.holds.coverage.active       # holds on credits and on the whole wallet
wallet.holds.reservations.active   # pending reservations
credit.holds.active                # the reasons this credit is held
```

The `Wallets::Hold` scopes are `active` (which takes `at:`), `released`, `coverage`, `reservations`, `wallet_scoped` and `credit_scoped`. Each hold answers `active?`, `released?`, `lapsed?` (its deadline passed without a release), `captured?`, `reservation?`, `coverage?`, `wallet_scoped?` and `credit_scoped?`. A credit hold reaches its credit through `hold.credit`. The column is `transaction_id`, but Active Record reserves the name `transaction`, so there is no `hold.transaction`. Each credit answers `held?`, `held_amount` and `available_amount`.

### Reserving value you are about to charge

A reservation sets an amount aside, like a card charge that stays pending until the merchant captures it:

```ruby
wallet.balance   # => 10000

reservation = wallet.reserve(3_000, category: :booking, until: 7.days.from_now, metadata: { booking_id: 42 })

wallet.balance        # => 7000
wallet.held_balance   # => 3000
```

When the service is delivered, capture what it really cost. The rest of the reservation is released in the same step:

```ruby
debit = reservation.capture!(2_750, category: :booking_charge, metadata: { booking_id: 42 })

wallet.balance                    # => 7250
reservation.captured?             # => true
reservation.capture_transaction   # => debit
```

Leave the amount out to capture the whole reservation. If the booking is cancelled, `reservation.release!` gives the amount back. If the deadline passes first, the reservation lapses and its amount is available again.

Reservations add up, like two pending card charges:

```ruby
wallet.reserve(40, category: :booking)
wallet.reserve(40, category: :booking)

wallet.held_balance   # => 80
```

The rules:

- **A reservation is funded like a debit.** It must fit in `balance`, or it raises `Wallets::InsufficientBalance`, unless `allow_negative_balance` is on. The amount is parsed exactly like a debit's, and `until:` must be a time: anything else raises `ArgumentError` instead of quietly meaning "no deadline".
- **A capture happens once.** Only an active reservation can be captured. A second capture, or a capture after a release or a lapse, raises `Wallets::InvalidHold` and creates nothing, so a retried request never charges twice. Capturing more than was reserved raises `ArgumentError`. The reservation's state is checked before the amount, so retrying a finished capture always raises `Wallets::InvalidHold`.
- **A capture is funded when it happens.** It spends credits like any debit, with its own reservation counted back in. Held value is never captured, so a fraud hold placed after the reservation can make the capture fail with `Wallets::InsufficientBalance`, and so can expiry. A failed capture leaves the reservation as it was, ready to try again.
- **A capture is one step.** Its balance snapshots and callbacks see the balance before and after the whole step, never the moment in between. Capturing the whole reservation of a fully reserved wallet reports an available balance of `0` before and `0` after. A capture never lowers the available balance: it takes at most what the reservation already kept out of it.

### Ending a hold by taking the value

Releasing a hold gives the value back. Sometimes the answer is the opposite: the reward was rejected, or the payment behind it bounced, and the value has to go. Name the credits to take it from with `from:`.

> [!WARNING]
> **`from:` is the one way to spend held value.** A plain `debit` or `transfer_to` never touches it. Reach for `from:` only when taking held value is exactly what you mean, such as cancelling a rejected reward.

```ruby
credit = wallet.credit(751, category: :reward, hold: :pending_validation)

# The reward was rejected: take it back...
wallet.debit(751, category: :reversal, from: credit, metadata: { reason: "reward_rejected" })

# ...or move it to the platform instead.
wallet.transfer_to(platform_wallet, 751, category: :reversal, from: credit)
```

Name several credits as a list, or pass any relation. They are spent in the order given, and a credit with nothing left simply gives nothing:

```ruby
wallet.debit(150, category: :reversal, from: [first_credit, second_credit])
```

How a debit with `from:` is funded:

- **It takes from the named credits only, in full or not at all.** It never falls back to other credits and never leaves debt, whatever `allow_negative_balance` says. Asking for more than the named credits hold raises `Wallets::InsufficientBalance`.
- **Held value needs no funding.** It was never part of the available balance, so cancelling a fully held credit works even when nothing is available.
- **Unheld value does.** With overdrafts off, the part taken from unheld credits must fit in the available balance. So naming an unheld credit cannot spend what a reservation set aside, or deepen a deficit.
- **Only saved, unexpired credits of this wallet.** An expired credit raises `ArgumentError` under every transfer expiration policy, because it would hand on value that no longer exists. So does every other bad source: an empty list, a credit named twice, a debit, an unsaved or deleted credit, another wallet's credit or another ledger's, and `from: nil` (leave `from:` out to spend as usual). All of them are refused before anything is written.
- **The holds stay where they are.** The credit keeps its reasons, with nothing left to hold. No `on_hold_released` fires, because nothing was released.
- **A transfer with `from:` always keeps its sources' expirations** under the default `:preserve` policy. It is always fully backed by the named credits, even when the value was held and nothing was available.

### How holds change the rules you already know

- **Holds decide which credits can fund a debit, and `allow_negative_balance` decides whether a debit nothing funds may go ahead.** An ordinary debit, transfer or capture skips held credits. With overdrafts on, whatever unheld credits cannot cover becomes debt, and held value is still never touched.
- **A hold is not a ban.** It keeps value from being spent. It does not stop the wallet from receiving credits, and it does not stop your app from doing anything. If an action must be blocked during a review, such as a withdrawal, check for that in your app and show the hold as the reason.
- **The available balance is a signed integer, and it can go negative without any overdraft.** Reserve 80 of 100, then hold the credit for fraud review:

  ```ruby
  wallet.reserve(80, category: :booking)
  wallet.hold(credit, category: :fraud_review)

  wallet.balance         # => -80
  wallet.held_balance    # => 180
  wallet.total_balance   # => 100
  ```

  Reserved value that expires has the same effect. With `allow_negative_balance` off, such a wallet stays perfectly usable: credits and releases work, and new spending is refused until the balance covers it. The flag decides what commands may do, not what the balance may read.
- **`held_balance` can be larger than `total_balance`.** It happens above, where a hold covers value that is also reserved, and when reserved value expires. It is deliberately not capped, and `total_balance == balance + held_balance` still applies.
- **A hold never pauses expiry.** A held credit that expires is gone, not held: its `held_amount` drops to `0`, while the hold stays readable as the reason it was held.
- **Deadlines are computed, never announced.** When an `until:` passes, the hold simply stops counting (`lapsed?`), exactly like an expired credit. No job runs and no callback fires: `on_hold_released` fires only for `release!` and for a capture.
- **The `:preserve` fallback follows what is really unbacked.** A transfer falls back to a single evergreen credit (`:none`) only when part of it is actually unbacked debt, not whenever it exceeds the available balance. This changes one case even without holds: with old debt and fresh expiring credits, a transfer above the net available balance that those credits fully cover now keeps their expiration instead of arriving evergreen.
- **`insufficient_balance` says what is out of reach.** Its metadata gains `held:` (credit value under holds) and `reserved:` (active reservations), so `available + held + reserved` is the total balance. Both are `0` when nothing is held. The error message names the ones that are not zero: `Insufficient balance (20 < 40; 100 held, 30 reserved)`. A debit with `from:` adds `covered_consumed:` (the held value it would have taken), and a capture adds `available_for_capture:`. Their messages say what was compared, such as `(100 < 101 in the named credits; ...)`, `(10 < 61 - 50 from held credits; ...)` or `(0 < 80 to capture reservation 5; ...)`.
- **Every change writes the wallet row.** Each command that records something updates the wallet's `updated_at`, even when the available balance does not move, as with a second reason on a held credit or a whole capture. Do not read a new `updated_at` as "the balance changed".
- **The cached `balance` column stores the available balance.** As before, it can go stale through time alone (expiry, and now deadlines), so call `wallet.balance` when the number matters.

### Hold callbacks

```ruby
Wallets.configure do |config|
  config.on_hold_created do |ctx|
    Rails.logger.info("[Wallets] #{ctx.category} hold on wallet #{ctx.wallet.id}, available #{ctx.previous_balance} -> #{ctx.new_balance}")
  end

  config.on_hold_released do |ctx|
    if ctx.transaction
      Rails.logger.info("[Wallets] Reservation #{ctx.hold.id} captured as transaction #{ctx.transaction.id}")
    else
      Rails.logger.info("[Wallets] Hold #{ctx.hold.id} released: #{ctx.hold.release_reason}")
    end
  end
end
```

On both events:

- `ctx.hold` is the `Wallets::Hold`, and `ctx.category` is its category.
- `ctx.amount` is a reservation's amount, and `nil` for a hold on a credit or a wallet. On a capture it is still the reserved amount: the debit carries what was captured.
- `ctx.previous_balance` and `ctx.new_balance` are available balances.
- `ctx.metadata` is the creation metadata on `on_hold_created` and the release metadata on `on_hold_released`. A capture's metadata lives on its debit.
- `ctx.transaction` is set only when a capture ended the reservation, and it is the debit.

What each command reports:

| Command | Callbacks |
|---|---|
| `credit(..., hold:)` | `on_balance_credited`, then `on_hold_created` |
| `hold`, `reserve` | `on_hold_created` |
| `release!` | `on_hold_released`, or nothing when the hold had already ended |
| `capture!` | `on_balance_debited`, then `on_hold_released` |
| `debit(..., from:)` | `on_balance_debited` only: nothing is released |
| A deadline passing | Nothing |

A hold, a reservation or a debit that lowers the available balance can also fire `on_low_balance_reached` and `on_balance_depleted`, once per real crossing. A credit, a release and a deadline never do. Like every success callback, these run after the outermost database transaction commits.

### Upgrading an existing install

```bash
bundle update wallets
rails generate wallets:upgrade
rails db:migrate
```

The upgrade generator writes one migration that adds the holds table to a 0.1, 0.2 or 0.3 install. It follows your `table_prefix`, and reads the key types from the tables you already have, uuid and unsigned keys included. Running it again never writes a second migration, and it writes none at all when the holds table already exists. Rolling the migration back drops the table only while it is empty. Fresh installs get the table from `rails generate wallets:install`.

Then look at where your app reads `wallet.balance`. It still means "what can be spent", so spending checks need no change. Screens and reports that mean "everything the user has", such as a total earned or a reconciliation against the cached column, should read `total_balance`.

### Embedding holds in your own ledger

Holds are opt-in per ledger. `Wallets::Wallet` keeps them. `Wallets::WalletBase`, the class embedding gems subclass, does not, until your subclass sets `hold_class_name`. A ledger that has not opted in never touches holds:

- `balance` runs the 0.3 math through the two helpers you may override, `positive_remaining_balance` and `unbacked_negative_balance(scope)`, which keep their signatures and their meaning. No hold SQL runs anywhere, destroy included.
- `held_balance` is `0`, `on_hold?` is `false`, and `available_balance` and `total_balance` both equal your `balance`, whatever your `current_balance` override returns.
- `hold`, `reserve`, `credit(hold:)`, `credit(available_at:)` and `from:` raise `Wallets::HoldsNotEnabled` before running a single query.

To opt in, give your ledger its own hold class and table, declare the associations, and set `hold_class_name`:

```ruby
class MyGem::Hold < Wallets::HoldBase
  self.embedded_table_name = "my_gem_holds"
  self.config_provider = -> { MyGem.configuration }

  belongs_to :wallet, class_name: "MyGem::Wallet", inverse_of: :holds
  belongs_to :credit, class_name: "MyGem::Transaction", foreign_key: :transaction_id, inverse_of: :holds, optional: true
  belongs_to :capture_transaction, class_name: "MyGem::Transaction", optional: true
end

class MyGem::Transaction < Wallets::TransactionBase
  has_many :holds, class_name: "MyGem::Hold", foreign_key: :transaction_id, inverse_of: :credit
end

class MyGem::Wallet < Wallets::WalletBase
  self.hold_class_name = "MyGem::Hold"
  self.callback_event_map = callback_event_map.merge(hold_created: :coins_held, hold_released: :coins_released).freeze

  has_many :holds, class_name: "MyGem::Hold", foreign_key: :wallet_id, inverse_of: :wallet
end
```

- Create the table with the same columns, check constraints and indexes as `wallets_holds`. The install template has them.
- If your wallets can be destroyed, destroy their holds first. `Wallets::Wallet` does it in a `before_destroy` callback declared with `prepend: true`, so the holds go before the transactions they point at.
- If you override `current_balance`, decide on purpose how it treats held and reserved value. With holds on, `balance`, `held_balance` and `total_balance` come from one set of terms. Overriding `current_balance` alone can break `total_balance == balance + held_balance`, so keep all three coherent.
- `credit` now takes the keywords `hold:` and `available_at:`, and `debit` takes `from:`. If your transaction table has columns by those names, you can no longer pass them through `credit` or `debit` as extra attributes.

### Performance and concurrency

With holds on, `balance`, `held_balance` and `total_balance` are each one SQL statement: the same sums over the wallet's transactions as before, plus an indexed `EXISTS` lookup on the holds table for each credit and one sum over the active reservations. Without holds, reading a balance runs exactly the 0.3 queries.

On MySQL, a transaction's snapshot is fixed by its first read (repeatable read). If your code reads something and then calls a wallet command in the same transaction, a plain read taken after the wallet lock could miss what another transaction just committed to that wallet. So each command compares the wallet row its snapshot shows with the row the lock returns. When they differ, that command's ledger reads become locking reads, which always see the latest rows, and so do the reads of every later command in the same transaction, until that transaction commits or rolls back. A wallet your own code saved or touched earlier in the transaction counts as stale too, because its snapshot would otherwise look current. Locking reads are not used every time, because InnoDB's gap locks would then make unrelated wallets deadlock each other. PostgreSQL and SQLite always read the latest rows and never need this. It relies on every ledger change going through the wallet API, which writes the wallet row each time: raw SQL writes to the wallet row (`update_columns` included), and holds written as `Wallets::Hold` rows instead of through `hold`, `reserve` and `credit(hold:)`, are outside the supported API. The full reasoning is in [the 0.4 plan](docs/plans/2026-10-17-holds-and-reservations.md#6-operations).

### Not in this release

- **Partial holds on a credit.** A credit hold always holds the credit's whole remaining value. To set an amount aside, reserve it.
- **Holds on incoming transfers.** `transfer_to` cannot yet issue the recipient's credits under an atomic initial hold. The recipient side can hold them with `wallet.hold(credit, ...)` after the transfer, but that second step is not atomic with it:

  ```ruby
  transfer = buyer_wallet.transfer_to(seller_wallet, 5_000, category: :sale)

  transfer.inbound_transactions.each do |credit|
    seller_wallet.hold(credit, category: :return_window, until: 14.days.from_now)
  end
  ```

- **Deadline notifications.** Nothing fires when an `until:` passes. Schedule your own job if you need to act at that moment.
- **Bucket pinning.** A reservation is an amount of the wallet, not a claim on particular credits. Ordinary debits leave it backed by the longest-lived credits, but expiry can still leave it underfunded.

## Configuration

Create or edit `config/initializers/wallets.rb`:

```ruby
Wallets.configure do |config|
  config.default_asset = :coins

  # Useful for direct credit/debit events in your app.
  # Transfer business categories live on Wallets::Transfer.category.
  config.additional_categories = %w[
    quest_reward
    provider_bonus
    payout
    promo_credit
  ]

  config.allow_negative_balance = false
  config.low_balance_threshold = 50
  config.transfer_expiration_policy = :preserve
end
```

## Callbacks

`wallets` ships with lifecycle callbacks you can use for notifications, analytics, or product logic.

Successful callbacks run after the outermost database transaction commits. If a caller wraps a wallet operation in a larger transaction and later rolls it back, no success callback is emitted. Callback exceptions are logged and isolated from the already-committed ledger write. `on_insufficient_balance` remains immediate because it describes a rejected operation rather than a committed row.

```ruby
Wallets.configure do |config|
  config.on_balance_credited do |ctx|
    Rails.logger.info("Wallet #{ctx.wallet.id} credited by #{ctx.amount}")
  end

  config.on_balance_debited do |ctx|
    Rails.logger.info("Wallet #{ctx.wallet.id} debited by #{ctx.amount}")
  end

  config.on_transfer_completed do |ctx|
    Rails.logger.info("Transfer #{ctx.transfer.id} completed")
  end

  config.on_low_balance_reached do |ctx|
    UserMailer.low_balance(ctx.wallet.owner).deliver_later
  end

  config.on_insufficient_balance do |ctx|
    Rails.logger.warn("Insufficient balance: #{ctx.metadata[:required]}")
  end
end
```

Useful fields on `ctx` include:

- `ctx.wallet`
- `ctx.transfer`
- `ctx.amount`
- `ctx.previous_balance`
- `ctx.new_balance`
- `ctx.transaction`
- `ctx.hold` (hold events, see [Hold callbacks](#hold-callbacks))
- `ctx.category`
- `ctx.metadata`

## wallets vs usage_credits — which gem do I need?

Both gems handle balances, but they solve different problems:

```
┌─────────────────────────────────────────────────────────────────┐
│                      usage_credits                              │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │  Subscriptions, Credit Packs, Pay Integration, Fulfillment│  │
│  │  Operations DSL, Pricing, Refunds, Webhook Handling       │  │
│  └───────────────────────────────────────────────────────────┘  │
│                            │                                    │
│                            ▼                                    │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │                       wallets                             │  │
│  │    Balance, Credit, Debit, Transfer, Expiration, FEFO,    │  │
│  │    Audit Trail, Row-Level Locking, Multi-Asset            │  │
│  └───────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

| Aspect | `wallets` | `usage_credits` |
|--------|-----------|-----------------|
| **Core job** | Store and move value | Sell and consume value |
| **Balance model** | Multi-asset (`:gb`, `:eur`, `:gems`) | Single asset (credits) |
| **Consumption** | Passive — balance depletes over time | Active — `spend_credits_on(:operation)` |
| **Transfers** | Built-in between users | Not designed for this |
| **Subscriptions** | You handle externally | Built-in with Stripe via `pay` |
| **Operations DSL** | None | `operation :send_email { costs 1.credit }` |
| **Best for** | B2C: games, telecom, rewards, marketplaces | B2B: SaaS, APIs, AI apps |

### When to use `wallets` alone

Use `wallets` directly when your product:
- Needs **multiple asset types** — `user.wallet(:wood)`, `user.wallet(:gold)`, `user.wallet(:eur)`
- Has **passive consumption** — balance depletes from usage over time (data, minutes, energy)
- Needs **user-to-user transfers** — gifting, P2P payments, marketplace settlements
- Manages its own subscription logic — or doesn't need subscriptions at all

### When to use `usage_credits`

Use `usage_credits` when your product:
- Sells **credits for specific operations** — "Process image costs 10 credits"
- Needs **Stripe subscriptions** with automatic credit fulfillment
- Wants the **operations DSL** — `spend_credits_on(:generate_report)`
- Is a **B2B/SaaS/API product** with usage-based pricing

### When to use both together

For products like a **SIM/telecom app**, you might use both:

```ruby
# usage_credits handles ACQUISITION (how users get balance)
subscription_plan :basic_data do
  stripe_price "price_xyz"
  gives 10_000.credits.every(:month)  # 10 GB in MB
end

# wallet-level movement is still available underneath usage_credits
user.credit_wallet.transfer_to(friend.credit_wallet, 3_000)  # Gift 3 GB
user.credit_wallet.balance  # => 7000 MB remaining
```

> [!TIP]
> `usage_credits` uses `wallets` as its ledger core. If you only need `usage_credits`, you get `wallets` for free underneath. Wallet-level methods like `user.credit_wallet.transfer_to(...)` are still available there, but the transfer DX intentionally lives at the wallet layer rather than the credits DSL.

## Real-world examples

### Telecom / Mobile data app

A SIM card app where users get monthly data and can transfer unused GBs to friends:

```ruby
class User < ApplicationRecord
  has_wallets default_asset: :data_mb  # Store in MB for precision
end

# Monthly plan grants 10 GB (stored as 10,240 MB)
user.wallet(:data_mb).credit(
  10_240,
  category: :monthly_plan,
  expires_at: 1.month.from_now,
  metadata: { plan: "basic", period: "2024-03" }
)

# Network usage consumes data passively
user.wallet(:data_mb).debit(512, category: :network_usage)

# User transfers 3 GB to a friend
user.wallet(:data_mb).transfer_to(
  friend.wallet(:data_mb),
  3_072,
  category: :gift,
  metadata: { message: "Here's some extra data!" }
)

user.wallet(:data_mb).balance  # => 6656 MB (6.5 GB remaining)
```

> [!NOTE]
> Store data in the smallest practical unit (MB or KB, not GB as a float). `wallets` uses integers to avoid floating-point issues.

### Game economy

A farming/strategy game with multiple resources:

```ruby
class Player < ApplicationRecord
  has_wallets default_asset: :gold
end

# Quest rewards multiple resources
player.wallet(:wood).credit(100, category: :quest_reward, metadata: { quest: "forest_patrol" })
player.wallet(:stone).credit(50, category: :quest_reward)
player.wallet(:gold).credit(25, category: :quest_reward)

# Crafting consumes resources
player.wallet(:wood).debit(30, category: :crafting, metadata: { item: "wooden_sword" })

# Premium currency from in-app purchase
player.wallet(:gems).credit(500, category: :purchase, metadata: { sku: "gem_pack_500" })

# Seasonal event with expiring currency
player.wallet(:snowflakes).credit(
  1_000,
  category: :event_reward,
  expires_at: Date.new(2024, 1, 7)  # Winter event ends
)

# Trading between players
player.wallet(:gold).transfer_to(
  other_player.wallet(:gold),
  100,
  category: :trade,
  metadata: { item_received: "rare_armor" }
)
```

### Home services booking app

A home-services app where the platform collects the customer payment, keeps its fee, and later pays the provider:

```ruby
class User < ApplicationRecord
  has_wallets default_asset: :usd_cents
end

class Marketplace < ApplicationRecord
  has_wallets default_asset: :usd_cents
end

sara = User.find(1)        # customer
lucia = User.find(2)       # cleaner
booking = Booking.find(42)
marketplace = Marketplace.first

# Booking completed
booking_total = 5000  # $50.00
platform_fee = (booking_total * 0.10).to_i  # 10%
provider_earnings = booking_total - platform_fee

# Customer pays the marketplace
charge = sara.wallet(:usd_cents).transfer_to(
  marketplace.wallet(:usd_cents),
  booking_total,
  category: :booking_charge,
  metadata: {
    booking_id: booking.id,
    provider_id: lucia.id
  }
)

# Marketplace pays the cleaner the net amount
payout = marketplace.wallet(:usd_cents).transfer_to(
  lucia.wallet(:usd_cents),
  provider_earnings,
  category: :provider_payout,
  metadata: {
    booking_id: booking.id,
    gross_amount: booking_total,
    platform_fee: platform_fee,
    customer_id: sara.id,
    booking_charge_transfer_id: charge.id
  }
)

# Cleaner later cashes out to Stripe
lucia.wallet(:usd_cents).debit(
  lucia.wallet(:usd_cents).balance,
  category: :payout,
  metadata: { stripe_transfer_id: "tr_xxx" }
)
```

### Loyalty programs & Reward points

Whether you're building a Starbucks-style loyalty program, credit card rewards, airline miles, or a Sweatcoin-style earn-from-actions app — it's the same pattern:

```
┌─────────────────────────────────────────────────────────────┐
│                   Loyalty program flow                      │
├─────────────────────────────────────────────────────────────┤
│  EARN              │  Purchase, action, referral, promo     │
│  HOLD              │  Points accumulate, some may expire    │
│  TRANSFER          │  Gift to family, pool with friends     │
│  REDEEM            │  Rewards, discounts, gift cards        │
└─────────────────────────────────────────────────────────────┘
```

```ruby
class User < ApplicationRecord
  has_wallets default_asset: :points
end

# ═══════════════════════════════════════════════════════════
# EARN — from purchases, actions, referrals
# ═══════════════════════════════════════════════════════════

# Points from purchase (1 point per dollar)
user.wallet(:points).credit(
  order.total_cents / 100,
  category: :purchase,
  metadata: { order_id: order.id }
)

# Bonus points for specific products
user.wallet(:points).credit(150, category: :bonus_item, metadata: { sku: "featured_product" })

# Referral bonus
user.wallet(:points).credit(500, category: :referral, metadata: { referred_user_id: friend.id })

# Daily check-in streaks
user.wallet(:points).credit(50 * streak_multiplier, category: :daily_checkin)

# Receipt scanning (Ibotta-style)
user.wallet(:points).credit(100, category: :receipt_scan, metadata: { receipt_id: 123 })

# ═══════════════════════════════════════════════════════════
# EXPIRING PROMOS — use-it-or-lose-it campaigns
# ═══════════════════════════════════════════════════════════

# Welcome bonus that expires in 30 days
user.wallet(:points).credit(
  500,
  category: :welcome_bonus,
  expires_at: 30.days.from_now
)

# Double points weekend (expires Monday)
user.wallet(:points).credit(
  200,
  category: :promo,
  expires_at: Date.current.next_occurring(:monday),
  metadata: { campaign: "double_points_weekend" }
)

# Birthday reward
user.wallet(:points).credit(
  1000,
  category: :birthday,
  expires_at: 1.month.from_now,
  metadata: { birthday_year: Date.current.year }
)

# ═══════════════════════════════════════════════════════════
# TRANSFER — gift to friends, pool with family
# ═══════════════════════════════════════════════════════════

# Gift points to another member
user.wallet(:points).transfer_to(
  friend.wallet(:points),
  500,
  category: :gift,
  metadata: { message: "Happy birthday!" }
)

# Family pooling (multiple transfers to a shared account)
family_members.each do |member|
  member.wallet(:points).transfer_to(
    family_pool.wallet(:points),
    member.wallet(:points).balance,
    category: :family_pool
  )
end

# ═══════════════════════════════════════════════════════════
# REDEEM — rewards, discounts, cash out
# ═══════════════════════════════════════════════════════════

# Redeem for a reward
user.wallet(:points).debit(
  2500,
  category: :redemption,
  metadata: { reward: "free_coffee", reward_id: 42 }
)

# Redeem for statement credit / gift card
user.wallet(:points).debit(
  10_000,
  category: :cash_out,
  metadata: { gift_card_code: "XXXX-YYYY", value_cents: 1000 }
)

# Partial redemption with points + cash
points_portion = 500
user.wallet(:points).debit(
  points_portion,
  category: :partial_redemption,
  metadata: { order_id: order.id, points_value_cents: points_portion }
)
```

**Loyalty-specific patterns:**

| Pattern | Implementation |
|---------|----------------|
| **Tiered earning** | `credit(amount * tier_multiplier, ...)` |
| **Points expiration** | `expires_at: 1.year.from_now` |
| **Family pooling** | `transfer_to` family wallet |
| **Gifting** | `transfer_to` friend's wallet |
| **Earn + burn in one transaction** | `debit` points, `credit` new promo points |
| **Points + cash** | `debit` points portion, charge card for remainder |

**Real-world examples this pattern fits:**

- Starbucks Stars
- Airline miles (Delta SkyMiles, United MileagePlus)
- Credit card points (Chase Ultimate Rewards, Amex MR)
- Hotel points (Marriott Bonvoy, Hilton Honors)
- Retail loyalty (Sephora Beauty Insider, REI Co-op)
- Cashback apps (Rakuten, Ibotta, Fetch)
- Fitness rewards (Sweatcoin, Stepn)

### Gig economy / Driver earnings

An Uber/DoorDash-style app with earnings and tips:

```ruby
class Driver < ApplicationRecord
  has_wallets default_asset: :usd_cents
end

# Ride completed
driver.wallet(:usd_cents).credit(
  1250,  # $12.50 base fare
  category: :ride_fare,
  metadata: { ride_id: ride.id, distance_miles: 5.2 }
)

# Tip added later
driver.wallet(:usd_cents).credit(
  300,  # $3.00 tip
  category: :tip,
  metadata: { ride_id: ride.id, rider_id: rider.id }
)

# Weekly payout
driver.wallet(:usd_cents).debit(
  driver.wallet(:usd_cents).balance,
  category: :weekly_payout,
  metadata: { payout_date: Date.current, bank_account: "****1234" }
)
```

## Perfect use cases

`wallets` is best for **closed-loop value** inside your app — where the app itself is the source of truth.

| Use case | Example | Why `wallets` fits |
|----------|---------|-------------------|
| **Telecom / data plans** | Mobile data that users can share | Multi-asset (`:data_mb`, `:sms`, `:minutes`), transfers, expiration |
| **Game economies** | FarmVille, Fortnite, OGame | Multiple resources, trading between players |
| **Marketplaces** | Etsy, Fiverr, Airbnb | Seller earnings, buyer credits, platform settlements |
| **Rewards / loyalty** | Sweatcoin, credit card points | Points from actions, expiring promos, redemptions |
| **Gig economy** | Uber, DoorDash | Driver earnings, tips, scheduled payouts |
| **Multi-currency** | Travel apps, international platforms | Per-currency wallets (`:eur`, `:usd`, `:gbp`) |
| **Store credit** | Gift cards, refund credits | Simple balance with full audit trail |

**Key signals that `wallets` is the right fit:**
- Users hold **multiple types of value** (not just one "credits" balance)
- Users **transfer value to each other** (gifts, trades, P2P payments)
- Value **expires** (promotional credits, seasonal currencies, data rollovers)
- You need a **full audit trail** (not just a cached integer)
- The app is the **source of truth** (not syncing with external ledgers)

## When NOT to use `wallets`

### Use `usage_credits` instead if:

- You're building a **SaaS/API product** with usage-based pricing
- You need **Stripe subscriptions** with automatic credit fulfillment
- You want an **operations DSL** like `spend_credits_on(:generate_report)`
- Your users **buy credits to perform specific actions** (not hold transferable balances)

See [usage_credits](https://github.com/rameerez/usage_credits) — it uses `wallets` underneath.

### Use something else entirely if:

`wallets` is the wrong abstraction when the hard part is external money movement, regulation, or accounting-grade settlement:

- **Banking infrastructure** — transfers to/from bank rails, cards, ACH, SEPA
- **Regulated stored-value** — KYC, AML, licensing, custody requirements
- **FX conversion** — multi-currency conversion with exchange rates
- **Full accounting** — charts of accounts, journal entries, financial reporting
- **Blockchain/crypto** — consensus, custody, cryptographic guarantees

### Skip both gems if:

- You just need **one cached integer** (`users.balance += 1`) and don't care about history, audits, or transfers
- Your "balance" is just a counter for display purposes

**Rule of thumb:**
- "How do I track balances and transfers inside my app?" → `wallets`
- "How do I sell credits for API/SaaS operations?" → `usage_credits`
- "How do I build payments infrastructure?" → Neither (you need a banking partner)

## Is this production-ready?

Yes, this is production-ready for internal app balances and user-to-user value transfer inside your product. It is substantially more trustworthy than a single integer column because it gives you an append-oriented transaction ledger, expiration-aware allocation, linked transfer records, balance snapshots, and row-level locking.

In practice, that means you get:

- a full transaction history instead of just a cached balance
- FEFO consumption of the soonest-expiring balance buckets, with oldest-first ties
- linked debit/credit records for transfers between users
- concurrency protection when multiple writes hit the same wallet
- enough structure to support marketplace balances, peer payments, rewards, and in-game assets inside a real production app

If your product needs users to hold value, earn value, spend value, or transmit value to other users inside your own app, this is the sort of foundation you want instead of `users.balance += 1`.

The wallet API is append-oriented, but the gem does not turn Active Record or your database into a tamper-proof store: application code with model/SQL access can still update rows, and destroying an owner intentionally cascades through that owner's wallet history. Use soft deletion or an application-level destroy restriction when records must be retained; also restrict write access, retain backups, reconcile against external processors, and use database/audit controls appropriate to your risk model. If you need legally immutable records, regulated custody, or accounting-grade journals, use purpose-built infrastructure.

## Can it support payments between users?

Yes. `transfer_to` lets you move value between users while keeping both sides of the movement linked in the ledger. That makes it suitable for peer payments, marketplace payouts, seller balances, rewards, and in-game trades inside your own app. It can also keep value pending, such as a seller's earnings until the return window closes, or set an amount aside until a charge is captured (see [Holds and reservations](#holds-and-reservations)).

But it is not a blockchain and not a full payments stack.

What it does not do for you:

- external settlement to banks or cards
- KYC/AML/compliance
- FX conversion between assets
- disputes, chargebacks, or processor reconciliation
- cryptographic consensus or custody guarantees

So the right framing is: strong internal wallet/accounting primitive, not money infrastructure by itself.

## Embedding `wallets` in your own gem

`wallets` is built to be embeddable: other gems can reuse the ledger core (expiration-aware allocation, locking, transfers, callbacks) on top of their **own** tables, config, and event names. This is exactly how [`usage_credits`](https://github.com/rameerez/usage_credits) works — its `UsageCredits::Wallet` is a `Wallets::WalletBase` subclass living in `usage_credits_*` tables.

> [!IMPORTANT]
> **Subclass the abstract `*Base` classes** (`Wallets::WalletBase`, `Wallets::TransactionBase`, `Wallets::AllocationBase`, `Wallets::TransferBase`, `Wallets::HoldBase`) — **not** the concrete `Wallets::Wallet` etc. ActiveRecord builds a subclass's attribute methods on its parent's, so subclassing a concrete model forces a schema load of the `wallets_*` tables — which don't exist in apps that only install your gem. The abstract parents make each embedded model its own `base_class`, so the base tables are never consulted.

These class-level hooks are a supported, stable contract (covered by tests — breaking them is a breaking change for downstream gems):

```ruby
class MyGem::Wallet < Wallets::WalletBase
  self.embedded_table_name = "my_gem_wallets"            # your table, not wallets_wallets
  self.config_provider = -> { MyGem.configuration }      # your config object
  self.callbacks_module = MyGem::Callbacks               # your callback dispatcher
  self.transaction_class_name = "MyGem::Transaction"     # your subclasses
  self.allocation_class_name = "MyGem::Allocation"
  self.transfer_class_name = "MyGem::Transfer"

  # Rename (or silence, with nil) core events for your domain:
  self.callback_event_map = {
    credited: :coins_added,
    debited: :coins_spent,
    insufficient: :not_enough_coins,
    low_balance: :low_balance,
    depleted: :out_of_coins,
    transfer_completed: nil  # nil = don't dispatch this event
  }.freeze

  class << self
    private

    # Customize the ledger entry recorded for `create_for_owner!(initial_balance:)`
    def initial_balance_credit_attributes
      { category: :starting_coins, metadata: { reason: "initial_balance" } }
    end
  end
end
```

Your `Transaction`, `Allocation`, and `Transfer` subclasses (of `Wallets::TransactionBase`, `Wallets::AllocationBase`, `Wallets::TransferBase`) set `embedded_table_name` (and `config_provider` / `transaction_class_name` where relevant) the same way.

One current limitation to be aware of: the core models declare their associations against the `Wallets::*` class names, so your subclasses should **re-declare associations** with your own classes (`belongs_to :wallet, class_name: "MyGem::Wallet"`, etc.) so that records load as your subclasses rather than the core ones. See `usage_credits`' models for the canonical embedding pattern.

Holds are opt-in for embedded ledgers. See [Embedding holds in your own ledger](#embedding-holds-in-your-own-ledger).

## TODO

- Dynamic association class resolution for embedded subclasses (so embedders don't need to re-declare associations)
- First-class transfer reversal/refund API built on compensating ledger entries
- Holds on incoming transfers (`transfer_to(..., hold:)`), so a recipient's credits can arrive held in the same step
- Partial credit holds, once a real use case shows whether two holds on one credit should overlap or add up
- Multi-step transfer policies beyond `:preserve`, `:none`, and fixed `expires_at`

## Development

Run the test suite:

```bash
bundle exec rake test
```

Run a specific appraisal:

```bash
bundle exec appraisal rails-7.2 rake test
bundle exec appraisal rails-8.1 rake test
```

## License

This project is available as open source under the terms of the [MIT License](LICENSE.txt).
