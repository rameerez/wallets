# frozen_string_literal: true

require "test_helper"

class WalletCallbacksTest < ActiveSupport::TestCase
  test "balance_credited callback receives the created transaction" do
    events = []
    Wallets.configure do |config|
      config.on_balance_credited { |ctx| events << ctx }
    end

    transaction = wallets_wallets(:rich_coins_wallet).credit(25, category: :reward)

    assert_equal 1, events.size
    assert_equal :balance_credited, events.first.event
    assert_equal transaction, events.first.transaction
    assert_equal 25, events.first.amount
  end

  test "balance_debited callback receives the created transaction" do
    events = []
    Wallets.configure do |config|
      config.on_balance_debited { |ctx| events << ctx }
    end

    transaction = wallets_wallets(:rich_coins_wallet).debit(25, category: :purchase)

    assert_equal 1, events.size
    assert_equal :balance_debited, events.first.event
    assert_equal transaction, events.first.transaction
    assert_equal 25, events.first.amount
  end

  test "transfer_completed callback receives the transfer" do
    events = []
    Wallets.configure do |config|
      config.on_transfer_completed { |ctx| events << ctx }
    end

    transfer = wallets_wallets(:rich_coins_wallet).transfer_to(
      wallets_wallets(:peer_coins_wallet),
      50,
      category: :peer_payment
    )

    assert_equal 1, events.size
    assert_equal :transfer_completed, events.first.event
    assert_equal transfer, events.first.transfer
    assert_equal 50, events.first.amount
  end

  test "low_balance_reached fires when crossing the configured threshold" do
    wallet = create_wallet(users(:new_user), asset_code: :gems, initial_balance: 150)
    events = []

    Wallets.configure do |config|
      config.low_balance_threshold = 100
      config.on_low_balance_reached { |ctx| events << ctx }
    end

    wallet.debit(75, category: :purchase)

    assert_equal 1, events.size
    assert_equal :low_balance_reached, events.first.event
    assert_equal 100, events.first.threshold
    assert_equal 150, events.first.previous_balance
    assert_equal 75, events.first.new_balance
  end

  test "balance_depleted fires when the balance reaches zero" do
    wallet = create_wallet(users(:new_user), asset_code: :wood, initial_balance: 50)
    events = []

    Wallets.configure do |config|
      config.on_balance_depleted { |ctx| events << ctx }
    end

    wallet.debit(50, category: :purchase)

    assert_equal 1, events.size
    assert_equal :balance_depleted, events.first.event
    assert_equal 50, events.first.previous_balance
    assert_equal 0, events.first.new_balance
  end

  # ───────────────────────────────────────────────────────────────────────────
  # depleted under `allow_negative_balance`
  # ───────────────────────────────────────────────────────────────────────────
  #
  # The original semantic was "fires when balance reaches exactly zero".
  # That breaks for apps with negative balances enabled — a single debit
  # can take a wallet from +100 to -50, skipping zero entirely. The
  # callback was conceptually about "ran out of available value", and a
  # negative balance is even more "out" than zero. The condition is
  # widened to `previous > 0 && new <= 0` so positive→negative crossings
  # also fire it. With negatives disabled, balance can't go below zero,
  # so `new <= 0` collapses back to `new == 0` and existing callers see
  # no behavior change.

  test "balance_depleted fires when a debit crosses zero straight into negative" do
    Wallets.configuration.allow_negative_balance = true
    wallet = create_wallet(users(:new_user), asset_code: :wood, initial_balance: 50)
    events = []

    Wallets.configuration.on_balance_depleted { |ctx| events << ctx }

    wallet.debit(120, category: :purchase)

    assert_equal 1, events.size
    assert_equal 50, events.first.previous_balance
    assert_equal(-70, events.first.new_balance)
    assert_equal(-70, wallet.reload.balance)
  end

  test "balance_depleted does not re-fire on already-negative wallets that go more negative" do
    Wallets.configuration.allow_negative_balance = true
    wallet = create_wallet(users(:new_user), asset_code: :wood, initial_balance: 0)
    wallet.debit(20, category: :purchase) # balance goes 0 → -20 (depleted fires once)
    events = []

    Wallets.configuration.on_balance_depleted { |ctx| events << ctx }
    wallet.debit(30, category: :purchase) # -20 → -50 (already depleted)

    assert_empty events, "depleted is one-shot per crossing — going deeper into negative does not re-fire"
  end

  test "balance_depleted re-fires after a positive bounce-back" do
    Wallets.configuration.allow_negative_balance = true
    wallet = create_wallet(users(:new_user), asset_code: :wood, initial_balance: 100)
    events = []

    Wallets.configuration.on_balance_depleted { |ctx| events << ctx }

    wallet.debit(150, category: :purchase) # 100 → -50, fires (1)
    wallet.credit(80, category: :reward)   # -50 → 30, no fire (credit)
    wallet.debit(60, category: :purchase)  # 30 → -30, fires (2)

    assert_equal 2, events.size, "depleted fires once per fresh crossing of the positive→non-positive boundary"
    assert_equal [100, 30], events.map(&:previous_balance)
    assert_equal [-50, -30], events.map(&:new_balance)
  end

  test "balance_depleted does not fire when a debit lands a wallet that was already non-positive" do
    Wallets.configuration.allow_negative_balance = true
    wallet = create_wallet(users(:new_user), asset_code: :wood, initial_balance: 0)
    events = []

    Wallets.configuration.on_balance_depleted { |ctx| events << ctx }
    wallet.debit(40, category: :purchase) # 0 → -40, previous was already non-positive

    assert_empty events, "previous balance must be strictly positive for depleted to fire"
  end

  test "low_balance_reached fires once when a debit drops a wallet below threshold and into negative" do
    Wallets.configuration.allow_negative_balance = true
    wallet = create_wallet(users(:new_user), asset_code: :gems, initial_balance: 200)
    events = []

    Wallets.configuration.low_balance_threshold = 50
    Wallets.configuration.on_low_balance_reached { |ctx| events << ctx }

    wallet.debit(300, category: :purchase) # 200 → -100, well below threshold

    assert_equal 1, events.size
    assert_equal 50, events.first.threshold
    assert_equal 200, events.first.previous_balance
    assert_equal(-100, events.first.new_balance)
  end

  test "low_balance_reached does not re-fire when an already-low wallet dips deeper" do
    Wallets.configuration.allow_negative_balance = true
    wallet = create_wallet(users(:new_user), asset_code: :gems, initial_balance: 30)
    Wallets.configuration.low_balance_threshold = 50
    events = []

    Wallets.configuration.on_low_balance_reached { |ctx| events << ctx }

    wallet.debit(80, category: :purchase) # 30 → -50, was already below threshold

    assert_empty events
  end

  test "insufficient_balance fires before raising" do
    wallet = wallets_wallets(:poor_coins_wallet)
    events = []

    Wallets.configure do |config|
      config.on_insufficient_balance { |ctx| events << ctx }
    end

    assert_raises(Wallets::InsufficientBalance) do
      wallet.debit(10, category: :purchase)
    end

    assert_equal 1, events.size
    assert_equal :insufficient_balance, events.first.event
    assert_equal 10, events.first.amount
    assert_equal 5, events.first.metadata[:available]
    assert_equal 10, events.first.metadata[:required]
  end

  test "a transfer dispatches debited, credited, and transfer_completed callbacks in order" do
    events = []
    Wallets.configure do |config|
      config.on_balance_debited { |ctx| events << [:debited, ctx] }
      config.on_balance_credited { |ctx| events << [:credited, ctx] }
      config.on_transfer_completed { |ctx| events << [:completed, ctx] }
    end

    transfer = wallets_wallets(:rich_coins_wallet).transfer_to(
      wallets_wallets(:peer_coins_wallet),
      50,
      category: :peer_payment
    )

    assert_equal [:debited, :credited, :completed], events.map(&:first)

    debited_context = events[0].last
    assert_equal :transfer_out, debited_context.category
    assert_equal "peer_payment", debited_context.metadata["transfer_category"]
    assert_equal wallets_wallets(:rich_coins_wallet).id, debited_context.wallet.id

    credited_context = events[1].last
    assert_equal :transfer_in, credited_context.category
    assert_equal wallets_wallets(:peer_coins_wallet).id, credited_context.wallet.id

    completed_context = events[2].last
    assert_equal transfer.id, completed_context.transfer.id
    assert_equal 50, completed_context.amount
  end

  test "successful callbacks are discarded when an enclosing transaction rolls back" do
    events = []
    Wallets.configuration.on_balance_credited { |ctx| events << ctx }
    wallet = wallets_wallets(:rich_coins_wallet)

    Wallets::Wallet.transaction do
      wallet.credit(25, category: :reward)
      raise ActiveRecord::Rollback
    end

    assert_empty events
    assert_equal 1000, wallet.reload.balance
  end

  test "transfer legs record balance snapshots on both wallets" do
    sender = create_wallet(users(:new_user), asset_code: :snap, initial_balance: 100)
    recipient = create_wallet(users(:peer_user), asset_code: :snap, initial_balance: 7)

    transfer = sender.transfer_to(recipient, 40, category: :gift)

    outbound = transfer.outbound_transaction
    inbound = transfer.inbound_transactions.sole

    assert_equal 100, outbound.balance_before
    assert_equal 60, outbound.balance_after
    assert_equal 7, inbound.balance_before
    assert_equal 47, inbound.balance_after
  end
end
