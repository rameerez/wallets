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
end
