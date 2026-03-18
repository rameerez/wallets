# frozen_string_literal: true

require "test_helper"

class Wallets::TransferTest < ActiveSupport::TestCase
  test "transfers value between wallets of the same asset" do
    sender = User.create!(email: "transfer-sender-#{SecureRandom.hex(4)}@example.com", name: "Transfer Sender")
    recipient = User.create!(email: "transfer-recipient-#{SecureRandom.hex(4)}@example.com", name: "Transfer Recipient")
    source_wallet = sender.wallet(:coins)
    target_wallet = recipient.wallet(:coins)
    source_wallet.credit(900, category: :top_up)

    transfer = source_wallet.transfer_to(
      target_wallet,
      250,
      category: :peer_payment,
      metadata: { note: "Thanks for the help" }
    )

    assert transfer.persisted?
    assert_equal "coins", transfer.asset_code
    assert_equal 250, transfer.amount
    assert_equal "preserve", transfer.expiration_policy
    assert_equal 650, source_wallet.reload.balance
    assert_equal 250, target_wallet.reload.balance
    assert_equal transfer.id, transfer.outbound_transaction.transfer_id
    assert_equal [transfer.id], transfer.inbound_transactions.pluck(:transfer_id).uniq
    assert_equal 1, transfer.inbound_transactions.count
    assert_equal "peer_payment", transfer.category
  end

  test "preserves expiration on the inbound transfer by default" do
    sender = create_wallet(users(:new_user), asset_code: :data_mb, initial_balance: 0)
    recipient = create_wallet(users(:peer_user), asset_code: :data_mb, initial_balance: 0)
    original_credit = sender.credit(10_240, category: :top_up, expires_at: 21.days.from_now)

    transfer = sender.transfer_to(recipient, 3_072, category: :gift)
    inbound = transfer.inbound_transactions.sole

    assert_equal "preserve", transfer.expiration_policy
    assert_equal 3_072, inbound.amount
    assert_equal original_credit.expires_at.to_i, inbound.expires_at.to_i
    assert_equal transfer.outbound_transaction.id, transfer.transactions.debits.sole.id
    assert_equal [inbound.id], transfer.transactions.credits.pluck(:id)
  end

  test "preserve splits inbound transfer legs across multiple source expirations" do
    sender = create_wallet(users(:new_user), asset_code: :wood, initial_balance: 0)
    recipient = create_wallet(users(:peer_user), asset_code: :wood, initial_balance: 0)
    earliest_bucket = sender.credit(100, category: :reward, expires_at: 5.days.from_now)
    later_bucket = sender.credit(80, category: :reward, expires_at: 20.days.from_now)

    transfer = sender.transfer_to(recipient, 130, category: :gift)
    inbound_legs = transfer.inbound_transactions.order(:expires_at, :id).to_a

    assert_equal 2, inbound_legs.size
    assert_nil transfer.inbound_transaction
    assert_equal [100, 30], inbound_legs.map(&:amount)
    assert_equal [earliest_bucket.expires_at.to_i, later_bucket.expires_at.to_i], inbound_legs.map { |tx| tx.expires_at.to_i }
    assert_equal 130, inbound_legs.sum(&:amount)
  end

  test "preserve groups inbound transfer legs by shared expiration" do
    sender = create_wallet(users(:new_user), asset_code: :stone, initial_balance: 0)
    recipient = create_wallet(users(:peer_user), asset_code: :stone, initial_balance: 0)
    shared_expiration = 14.days.from_now
    sender.credit(60, category: :reward, expires_at: shared_expiration)
    sender.credit(40, category: :reward, expires_at: shared_expiration)

    transfer = sender.transfer_to(recipient, 75, category: :gift)
    inbound = transfer.inbound_transactions.sole

    assert_equal 75, inbound.amount
    assert_equal shared_expiration.to_i, inbound.expires_at.to_i
  end

  test "none expiration policy creates evergreen inbound credits" do
    sender = create_wallet(users(:new_user), asset_code: :event_tokens, initial_balance: 0)
    recipient = create_wallet(users(:peer_user), asset_code: :event_tokens, initial_balance: 0)
    sender.credit(100, category: :reward, expires_at: 10.days.from_now)

    transfer = sender.transfer_to(recipient, 25, category: :gift, expiration_policy: :none)

    assert_equal "none", transfer.expiration_policy
    assert_nil transfer.inbound_transactions.sole.expires_at
  end

  test "configured transfer expiration policy is used when no explicit override is provided" do
    original_policy = Wallets.configuration.transfer_expiration_policy
    Wallets.configuration.transfer_expiration_policy = :none

    sender = create_wallet(users(:new_user), asset_code: :tickets, initial_balance: 0)
    recipient = create_wallet(users(:peer_user), asset_code: :tickets, initial_balance: 0)
    sender.credit(100, category: :reward, expires_at: 10.days.from_now)

    transfer = sender.transfer_to(recipient, 25, category: :gift)

    assert_equal "none", transfer.expiration_policy
    assert_nil transfer.inbound_transactions.sole.expires_at
  ensure
    Wallets.configuration.transfer_expiration_policy = original_policy
  end

  test "fixed expiration override applies the provided expires_at" do
    sender = create_wallet(users(:new_user), asset_code: :gems, initial_balance: 0)
    recipient = create_wallet(users(:peer_user), asset_code: :gems, initial_balance: 0)
    sender.credit(100, category: :reward, expires_at: 10.days.from_now)
    fixed_expiration = 45.days.from_now

    transfer = sender.transfer_to(
      recipient,
      25,
      category: :gift,
      expiration_policy: :fixed,
      expires_at: fixed_expiration
    )

    assert_equal "fixed", transfer.expiration_policy
    assert_equal fixed_expiration.to_i, transfer.inbound_transactions.sole.expires_at.to_i
  end

  test "fixed expiration override requires an expires_at value" do
    source_wallet = wallets_wallets(:rich_coins_wallet)
    target_wallet = wallets_wallets(:peer_coins_wallet)

    error = assert_raises(ArgumentError) do
      source_wallet.transfer_to(target_wallet, 10, category: :peer_payment, expiration_policy: :fixed)
    end

    assert_includes error.message, "expires_at"
  end

  test "custom expires_at without an explicit policy uses fixed transfer expiration" do
    sender = create_wallet(users(:new_user), asset_code: :ore, initial_balance: 0)
    recipient = create_wallet(users(:peer_user), asset_code: :ore, initial_balance: 0)
    sender.credit(100, category: :reward, expires_at: 8.days.from_now)
    fixed_expiration = 30.days.from_now

    transfer = sender.transfer_to(recipient, 25, category: :gift, expires_at: fixed_expiration)

    assert_equal "fixed", transfer.expiration_policy
    assert_equal fixed_expiration.to_i, transfer.inbound_transactions.sole.expires_at.to_i
  end

  test "rejects unsupported transfer expiration policies" do
    source_wallet = wallets_wallets(:rich_coins_wallet)
    target_wallet = wallets_wallets(:peer_coins_wallet)

    error = assert_raises(ArgumentError) do
      source_wallet.transfer_to(target_wallet, 10, category: :peer_payment, expiration_policy: :fresh_window)
    end

    assert_includes error.message, "expiration policy"
  end

  test "rejects transfers that exceed available balance even when negatives are enabled" do
    original_setting = Wallets.configuration.allow_negative_balance
    Wallets.configuration.allow_negative_balance = true

    sender = create_wallet(users(:new_user), asset_code: :credits, initial_balance: 10)
    recipient = create_wallet(users(:peer_user), asset_code: :credits, initial_balance: 0)

    assert_raises(Wallets::InsufficientBalance) do
      sender.transfer_to(recipient, 25, category: :gift)
    end
  ensure
    Wallets.configuration.allow_negative_balance = original_setting
  end

  test "rejects transfers across different assets" do
    source_wallet = wallets_wallets(:rich_coins_wallet)
    target_wallet = wallets_wallets(:rich_gems_wallet)

    assert_raises(Wallets::InvalidTransfer) do
      source_wallet.transfer_to(target_wallet, 10, category: :peer_payment)
    end
  end

  test "transfer model rejects the same wallet on both sides" do
    wallet = wallets_wallets(:rich_coins_wallet)

    transfer = Wallets::Transfer.new(
      from_wallet: wallet,
      to_wallet: wallet,
      asset_code: :coins,
      amount: 10,
      expiration_policy: :preserve
    )

    refute transfer.valid?
    assert_includes transfer.errors[:to_wallet], "must be different from from_wallet"
  end

  test "transfer model validates expiration policy" do
    source_wallet = wallets_wallets(:rich_coins_wallet)
    target_wallet = wallets_wallets(:peer_coins_wallet)

    transfer = Wallets::Transfer.new(
      from_wallet: source_wallet,
      to_wallet: target_wallet,
      asset_code: :coins,
      amount: 10,
      expiration_policy: :fresh_window
    )

    refute transfer.valid?
    assert_includes transfer.errors[:expiration_policy], "is not included in the list"
  end
end
