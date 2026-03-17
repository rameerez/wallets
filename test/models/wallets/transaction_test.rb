# frozen_string_literal: true

require "test_helper"

class Wallets::TransactionTest < ActiveSupport::TestCase
  test "default categories constant remains available for compatibility" do
    assert_equal Wallets::Transaction::DEFAULT_CATEGORIES, Wallets::Transaction::CATEGORIES
    assert_includes Wallets::Transaction::DEFAULT_CATEGORIES, "credit"
    assert_includes Wallets::Transaction::DEFAULT_CATEGORIES, "debit"
    assert_includes Wallets::Transaction::DEFAULT_CATEGORIES, "transfer_out"
  end

  test "accepts configured additional categories" do
    wallet = wallets_wallets(:rich_coins_wallet)

    transaction = Wallets::Transaction.new(
      wallet: wallet,
      amount: 25,
      category: "peer_payment"
    )

    assert transaction.valid?
  end

  test "categories include defaults and configured additions" do
    categories = Wallets::Transaction.categories

    assert_includes categories, "credit"
    assert_includes categories, "peer_payment"
  end

  test "credit and debit predicates reflect the sign of the amount" do
    assert wallets_transactions(:rich_top_up).credit?
    assert_not wallets_transactions(:rich_top_up).debit?
    assert wallets_transactions(:rich_purchase).debit?
    assert_not wallets_transactions(:rich_purchase).credit?
  end

  test "expired reflects expires_at" do
    assert wallets_transactions(:rich_expired_reward).expired?
    assert_not wallets_transactions(:rich_future_reward).expired?
    assert_not wallets_transactions(:rich_top_up).expired?
  end

  test "remaining_amount returns the unspent amount for positive transactions" do
    transaction = wallets_transactions(:rich_top_up)

    assert_equal 800, transaction.remaining_amount
  end

  test "remaining_amount is zero for debits" do
    assert_equal 0, wallets_transactions(:rich_purchase).remaining_amount
  end

  test "unbacked_amount returns zero for fully backed debits" do
    transaction = wallets_transactions(:rich_purchase)

    assert_equal 0, transaction.unbacked_amount
  end

  test "unbacked_amount is zero for positive transactions" do
    assert_equal 0, wallets_transactions(:rich_top_up).unbacked_amount
  end

  test "unbacked_amount returns leftover amount for negative balances" do
    original_setting = Wallets.configuration.allow_negative_balance
    Wallets.configuration.allow_negative_balance = true

    wallet = create_wallet(users(:new_user), asset_code: :credits, initial_balance: 10)
    transaction = wallet.debit(25, category: :purchase)

    assert_equal 15, transaction.unbacked_amount
  ensure
    Wallets.configuration.allow_negative_balance = original_setting
  end
end
