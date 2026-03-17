# 💼 `wallets` - Add user wallets with money-like balances to your Rails app

[![Gem Version](https://badge.fury.io/rb/wallets.svg)](https://badge.fury.io/rb/wallets) [![Build Status](https://github.com/rameerez/wallets/workflows/Tests/badge.svg)](https://github.com/rameerez/wallets/actions)

> [!TIP]
> **🚀 Ship your next Rails app 10x faster!** I've built **[RailsFast](https://railsfast.com/?ref=wallets)**, a production-ready Rails boilerplate template that comes with everything you need to launch a software business in days, not weeks. Go [check it out](https://railsfast.com/?ref=wallets)!

`wallets` gives any Rails model one or more app-managed wallets backed by an append-only transaction ledger.

Use it for:

- Multi-currency balances like `:eur`, `:usd`, or `:gbp`
- Game resources like `:wood`, `:stone`, `:gems`, or `:gold`
- Store credit, reward wallets
- Transferrable usage between users, like a SIM card app: "this plan gives you X GBs per month, you can transfer any unused GBs to other users"
- Marketplace seller balances and platform credits
- Gig economy earnings, rider/driver balances, or reward wallets
- Cashback, loyalty points, store credit, and in-app tokens

> [!TIP]
> If your product is specifically about usage-based credits for SaaS, APIs, or AI apps, [`usage_credits`](https://github.com/rameerez/usage_credits) is probably the better fit. `usage_credits` uses `wallets` underneath, and then adds handy DX ergonomics for credits, fulfillment, pricing, refills, packs, subscriptions, payment flows, and more. The `wallets` gem was extracted from `usage_credits`, and should only be used for when you need something like `usage_credits`, minus the credits-specific overhead. wallets = ledger/balance core; usage_credits = opinionated acquisition/product layer (subscriptions, packs/top-ups, Pay integration, recurring fulfillment)

`wallets` is a good fit for software that needs more than `users.balance += 1`, but does not need a full banking core.

Think:

- Games like Fortnite or FarmVille where users collect and spend different resources
- Marketplace flows like Etsy or Fiverr where users accrue balances and spend or transfer value internally
- Reward and gig apps in the style of DoorDash or Uber where users earn balance from actions over time

## Why this gem

`wallets` is built around a few practical ideas:

- One owner can have one wallet per asset: `user.wallet(:usd)`, `user.wallet(:eur)`
- Every balance change is tracked as a transaction
- Debits allocate against the oldest available credits first, so expiring value gets consumed first
- Transfers create linked records on both sides
- Row-level locking protects concurrent debits and transfers
- Metadata and balance snapshots give you a useful audit trail

## Quick start

Add the gem to your Gemfile:

```ruby
gem "wallets"
```

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

```ruby
class User < ApplicationRecord
  has_wallets default_asset: :eur
end

buyer = User.find(1)
seller = User.find(2)

buyer.wallet(:eur).credit(10_000, category: :top_up, metadata: { source: "card" })
buyer.wallet(:eur).debit(2_500, category: :purchase, metadata: { order_id: 42 })

buyer.wallet(:eur).transfer_to(
  seller.wallet(:eur),
  1_800,
  category: :marketplace_sale,
  metadata: { order_id: 42 }
)

buyer.wallet(:wood).credit(50, category: :quest_reward)
buyer.wallet(:wood).debit(10, category: :crafting)
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
transfer.inbound_transaction
```

Transfers require both wallets to use the same asset. `:eur` can move to `:eur`; `:wood` can move to `:wood`.

### Expiring balances

Credits can expire:

```ruby
user.wallet(:coins).credit(
  1_000,
  category: :season_reward,
  expires_at: 30.days.from_now
)
```

Debits allocate against the oldest available, non-expired credits first.

## Configuration

Create or edit `config/initializers/wallets.rb`:

```ruby
Wallets.configure do |config|
  config.default_asset = :coins

  # Useful for app-specific business events like games, marketplaces, or rewards.
  config.additional_categories = %w[
    quest_reward
    marketplace_sale
    ride_fare
    peer_payment
  ]

  config.allow_negative_balance = false
  config.low_balance_threshold = 50
end
```

## Callbacks

`wallets` ships with lifecycle callbacks you can use for notifications, analytics, or product logic.

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
- `ctx.category`
- `ctx.metadata`

## Real-world fit

### Games and virtual economies

Games often need more than one balance:

- `user.wallet(:wood)`
- `user.wallet(:stone)`
- `user.wallet(:gold)`
- `user.wallet(:gems)`

That maps well to strategy and farming games in the vein of OGame or FarmVille, or to games with premium and earned resources like Fortnite-style economies.

### Marketplaces

Marketplaces need more than a cached integer:

- buyer store credit
- seller earnings
- referral bonuses
- internal transfers
- auditable transaction history

`wallets` works well for Etsy-style, Fiverr-style, or platform-credit marketplace flows where the app is the source of truth for internal balances.

### Reward and gig apps

Many B2C apps reward users for actions:

- completing rides
- referring a friend
- finishing a challenge
- scanning receipts
- daily streaks

That maps naturally to cashback apps, loyalty products, and DoorDash/Uber/Sweatcoin-style internal earning systems.

## Perfect use cases

`wallets` is best for closed-loop value inside your app.

Use it when value is created, tracked, spent, and transferred inside your own product, and you want something much more trustworthy than a single integer column.

- In-game economies with multiple resources like `:wood`, `:stone`, `:gold`, and `:gems`.
- Marketplace internal balances like seller earnings, buyer credits, referral bonuses, and platform-managed payouts.
- Rewards, loyalty, cashback, and streak systems where users earn value from actions and redeem it later.
- Multi-asset apps where one user can hold several balances like `:eur`, `:usd`, `:credits`, or `:gems`.
- Internal peer-to-peer transfers, gifting, marketplace settlement, and in-app value movement between users.

It is especially strong when the app itself is the source of truth for the balance ledger.

## Anti use cases

`wallets` is the wrong abstraction when the hard part of the product is external money movement, regulation, or accounting-grade settlement.

- Bank-like money infrastructure with transfers to and from bank rails, cards, ACH, or SEPA.
- Regulated stored-value products where KYC, AML, licensing, or custody are core requirements.
- Escrow and held-balance systems with pending, available, reserved, or delayed-release states.
- Multi-currency conversion systems where FX rates and conversion rules are first-class concerns.
- Full accounting engines with charts of accounts, journal entries, financial reporting, and reconciliation.
- Blockchain or crypto-style systems where consensus, custody, and cryptographic guarantees matter.
- Extremely simple apps that only need one cached counter and do not care about history, auditability, transfer records, or expirations.

If the question is "how do I safely track balances and transfers inside my app?", this gem is a good fit.

If the question is "how do I build payments infrastructure or a banking system?", this gem is not enough by itself.

## Is this production-ready?

Yes, this is production-ready for internal app balances and user-to-user value transfer inside your product. It is substantially more trustworthy than a single integer column because it gives you an append-only ledger, FIFO allocation, linked transfer records, balance snapshots, and row-level locking.

In practice, that means you get:

- a full transaction history instead of just a cached balance
- FIFO consumption of the oldest available balance buckets
- linked debit/credit records for transfers between users
- concurrency protection when multiple writes hit the same wallet
- enough structure to support marketplace balances, peer payments, rewards, and in-game assets inside a real production app

If your product needs users to hold value, earn value, spend value, or transmit value to other users inside your own app, this is the sort of foundation you want instead of `users.balance += 1`.

## Can it support payments between users?

Yes. `transfer_to` lets you move value between users while keeping both sides of the movement linked in the ledger. That makes it suitable for peer payments, marketplace payouts, seller balances, rewards, and in-game trades inside your own app.

But it is not a blockchain and not a full payments stack.

What it does not do for you:

- external settlement to banks or cards
- KYC/AML/compliance
- escrow, reserves, or held balances
- FX conversion between assets
- disputes, chargebacks, or processor reconciliation
- cryptographic consensus or custody guarantees

So the right framing is: strong internal wallet/accounting primitive, not money infrastructure by itself.

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
