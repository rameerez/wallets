# 💼 `wallets` - Add user wallets with money-like balances to your Rails app

[![Gem Version](https://badge.fury.io/rb/wallets.svg)](https://badge.fury.io/rb/wallets) [![Build Status](https://github.com/rameerez/wallets/workflows/Tests/badge.svg)](https://github.com/rameerez/wallets/actions)

> [!TIP]
> **🚀 Ship your next Rails app 10x faster!** I've built **[RailsFast](https://railsfast.com/?ref=wallets)**, a production-ready Rails boilerplate template that comes with everything you need to launch a software business in days, not weeks. Go [check it out](https://railsfast.com/?ref=wallets)!

`wallets` gives any Rails model money-like wallets backed by an append-only transaction ledger. You can use these wallets to store and transfer value in any "currency" (points inside your app, call minutes, in-game resources, in-app assets, etc.)

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
| **Append-only ledger** | Every balance change is a transaction: no edits, only new entries |
| **FIFO allocation** | Debits consume oldest credits first (important for expiring balances) |
| **Linked transfers** | Both sides of a transfer are recorded and queryable |
| **Row-level locking** | Prevents race conditions and double-spending |
| **Balance snapshots** | Each transaction records before/after balance for reconciliation |
| **Rich metadata** | Attach any JSON to transactions for audit and filtering |

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
transfer.inbound_transactions
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
  config.transfer_expiration_policy = :preserve
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

## wallets vs usage_credits — which gem do I need?

Both gems handle balances, but they solve different problems:

```
┌─────────────────────────────────────────────────────────────────┐
│                      usage_credits                              │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │  Subscriptions, Credit Packs, Pay Intgration, Fulfillment │  │
│  │  Operations DSL, Pricing, Refunds, Webhook Handling       │  │
│  └───────────────────────────────────────────────────────────┘  │
│                            │                                    │
│                            ▼                                    │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │                       wallets                             │  │
│  │    Balance, Credit, Debit, Transfer, Expiration, FIFO,    │  │
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

### Marketplace with seller balances

An Etsy/Fiverr-style marketplace where sellers earn and can withdraw:

```ruby
class User < ApplicationRecord
  has_wallets default_asset: :usd_cents
end

# Order completed — credit seller (minus platform fee)
order_total = 5000  # $50.00
platform_fee = (order_total * 0.10).to_i  # 10%
seller_earnings = order_total - platform_fee

seller.wallet(:usd_cents).credit(
  seller_earnings,
  category: :sale,
  metadata: {
    order_id: order.id,
    gross_amount: order_total,
    platform_fee: platform_fee,
    buyer_id: buyer.id
  }
)

# Buyer uses store credit
buyer.wallet(:usd_cents).debit(
  2000,
  category: :purchase,
  metadata: { order_id: order.id }
)

# Seller requests payout
seller.wallet(:usd_cents).debit(
  seller.wallet(:usd_cents).balance,
  category: :payout,
  metadata: { stripe_transfer_id: "tr_xxx" }
)

# Transaction history for accounting
seller.wallet(:usd_cents).history.each do |tx|
  puts "#{tx.created_at}: #{tx.category} #{tx.amount} cents"
  puts "  Balance: #{tx.balance_before} → #{tx.balance_after}"
end
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
- **Escrow systems** — pending, available, reserved, delayed-release states
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

## TODO

- First-class transfer reversal/refund API built on compensating ledger entries
- Optional pending/held balance primitives for escrow-like flows
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
