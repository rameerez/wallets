# frozen_string_literal: true

require "test_helper"

class Wallets::WalletTest < ActiveSupport::TestCase
  test "computes balance from non-expired positive transactions minus allocations" do
    wallet = wallets_wallets(:rich_coins_wallet)

    assert_equal 1000, wallet.balance
  end

  test "credit creates a transaction and updates balance snapshots" do
    wallet = wallets_wallets(:rich_coins_wallet)

    transaction = wallet.credit(75, category: :reward, metadata: { source: "promo" })

    assert_equal 75, transaction.amount
    assert_equal 1000, transaction.balance_before
    assert_equal 1075, transaction.balance_after
    assert_equal 1075, wallet.reload.balance
  end

  test "debit allocates from the oldest available transactions first" do
    wallet = create_wallet(users(:new_user), asset_code: :wood, initial_balance: 0)

    oldest = wallet.credit(100, category: :top_up, metadata: { bucket: "oldest" })
    newer = wallet.credit(80, category: :reward, metadata: { bucket: "newer" })

    spend = wallet.debit(130, category: :purchase, metadata: { sku: "bundle" })
    allocations = spend.outgoing_allocations.order(:id)

    assert_equal oldest.id, allocations.first.source_transaction_id
    assert_equal 100, allocations.first.amount
    assert_equal newer.id, allocations.second.source_transaction_id
    assert_equal 30, allocations.second.amount
    assert_equal 50, wallet.reload.balance
  end

  test "debit raises when balance is insufficient and negatives are disabled" do
    wallet = wallets_wallets(:poor_coins_wallet)

    assert_raises(Wallets::InsufficientBalance) do
      wallet.debit(10, category: :purchase)
    end
  end

  test "debit tolerates nil metadata on insufficient balance checks" do
    wallet = wallets_wallets(:poor_coins_wallet)

    assert_raises(Wallets::InsufficientBalance) do
      wallet.debit(10, category: :purchase, metadata: nil)
    end
  end

  test "create_for_owner rejects negative initial balances" do
    assert_raises(ArgumentError) do
      Wallets::Wallet.create_for_owner!(
        owner: users(:new_user),
        asset_code: :credits,
        initial_balance: -5
      )
    end
  end

  test "create_for_owner is idempotent for an existing owner and asset" do
    owner = users(:new_user)

    wallet = Wallets::Wallet.create_for_owner!(
      owner: owner,
      asset_code: :ore,
      initial_balance: 25
    )

    assert_no_difference -> { Wallets::Wallet.where(owner: owner, asset_code: "ore").count } do
      same_wallet = Wallets::Wallet.create_for_owner!(
        owner: owner,
        asset_code: " ORE ",
        initial_balance: 75
      )

      assert_equal wallet.id, same_wallet.id
    end

    assert_equal 25, wallet.reload.balance
    assert_equal 1, wallet.transactions.count
    assert_equal "adjustment", wallet.transactions.sole.category
    assert_equal "initial_balance", wallet.transactions.sole.metadata["reason"]
  end

  test "negative balances are tracked correctly when enabled" do
    original_setting = Wallets.configuration.allow_negative_balance
    Wallets.configuration.allow_negative_balance = true

    wallet = create_wallet(users(:new_user), asset_code: :credits, initial_balance: 10)
    spend = wallet.debit(25, category: :purchase)

    assert_equal(-15, wallet.reload.balance)
    assert_equal(-25, spend.amount)
    assert_equal 15, spend.unbacked_amount
  ensure
    Wallets.configuration.allow_negative_balance = original_setting
  end
end
