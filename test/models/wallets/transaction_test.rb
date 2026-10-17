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

  test "zero amounts are invalid and nil amount predicates are safe" do
    wallet = wallets_wallets(:rich_coins_wallet)
    zero = Wallets::Transaction.new(wallet: wallet, amount: 0, category: "credit")
    missing = Wallets::Transaction.new(wallet: wallet, category: "credit")

    assert_not zero.valid?
    assert_includes zero.errors[:amount], "must be other than 0"
    assert_not missing.credit?
    assert_not missing.debit?
    assert_not missing.valid?
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

  # ───────────────────────────────────────────────────────────────────────────
  # Scopes
  # ───────────────────────────────────────────────────────────────────────────

  test "expired and not_expired scopes partition transactions at the boundary instant" do
    wallet = create_wallet(users(:new_user), asset_code: :boundary)
    boundary_time = 2.days.from_now.change(usec: 0)

    expiring = wallet.credit(10, category: :reward, expires_at: boundary_time)
    evergreen = wallet.credit(10, category: :top_up)

    travel_to boundary_time do
      assert_includes wallet.transactions.expired.pluck(:id), expiring.id
      refute_includes wallet.transactions.not_expired.pluck(:id), expiring.id
      assert_includes wallet.transactions.not_expired.pluck(:id), evergreen.id
      refute_includes wallet.transactions.expired.pluck(:id), evergreen.id

      assert expiring.reload.expired?, "a transaction expiring exactly now is already expired"
      assert_equal 10, wallet.balance, "balance counts only the evergreen bucket at the boundary"
    end
  end

  test "scopes slice the ledger by sign, category, and recency" do
    wallet = nil
    travel_to 2.minutes.ago do
      wallet = create_wallet(users(:new_user), asset_code: :scoped, initial_balance: 100)
    end
    seed = wallet.transactions.sole
    spend = wallet.debit(25, category: :purchase)

    assert_equal [seed.id], wallet.transactions.credits.pluck(:id)
    assert_equal [spend.id], wallet.transactions.debits.pluck(:id)
    assert_equal [spend.id], wallet.transactions.by_category(:purchase).pluck(:id)
    assert_equal [spend.id, seed.id], wallet.transactions.recent.pluck(:id)
  end

  test "amount and expiration scopes remain unambiguous when transfers are joined" do
    sender = create_wallet(users(:new_user), asset_code: :joined_scope, initial_balance: 100)
    recipient = create_wallet(users(:peer_user), asset_code: :joined_scope)
    transfer = sender.transfer_to(recipient, 25, category: :peer_payment)

    assert_equal transfer.outbound_transaction, sender.transactions.joins(:transfer).debits.sole
    assert_equal transfer.inbound_transaction, recipient.transactions.joins(:transfer).credits.sole

    table = Wallets::Transaction.table_name
    connection = Wallets::Transaction.connection
    qualified = ->(column) { "#{connection.quote_table_name(table)}.#{connection.quote_column_name(column)}" }
    assert_includes Wallets::Transaction.credits.to_sql, qualified.call(:amount)
    assert_includes Wallets::Transaction.debits.to_sql, qualified.call(:amount)
    assert_includes Wallets::Transaction.not_expired.to_sql, qualified.call(:expires_at)
    assert_includes Wallets::Transaction.expired.to_sql, qualified.call(:expires_at)
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Categories
  # ───────────────────────────────────────────────────────────────────────────

  test "categories fall back to the defaults when the config does not support extras" do
    minimal_config = Struct.new(:table_prefix).new("wallets_")
    Wallets::Transaction.stubs(:resolved_config).returns(minimal_config)

    assert_equal Wallets::Transaction::DEFAULT_CATEGORIES, Wallets::Transaction.categories
  end

  test "categories deduplicate overlap between defaults and extras" do
    Wallets.configuration.additional_categories = %w[credit special_bonus]

    categories = Wallets::Transaction.categories

    assert_equal 1, categories.count("credit")
    assert_includes categories, "special_bonus"
  end

  test "rejects categories outside the configured list" do
    transaction = Wallets::Transaction.new(
      wallet: wallets_wallets(:rich_coins_wallet),
      amount: 5,
      category: "made_up"
    )

    refute transaction.valid?
    assert_includes transaction.errors[:category], "is not included in the list"
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Allocation accounting and validations
  # ───────────────────────────────────────────────────────────────────────────

  test "allocated and spent amounts read from the allocation links" do
    top_up = wallets_transactions(:rich_top_up)     # +900 with 100 allocated away
    purchase = wallets_transactions(:rich_purchase) # -100 fully backed

    assert_equal 100, top_up.allocated_amount
    assert_equal 0, top_up.spent_amount
    assert_equal 100, purchase.spent_amount
    assert_equal 0, purchase.allocated_amount
  end

  test "a credit cannot be allocated beyond its amount" do
    top_up = wallets_transactions(:rich_top_up) # 900 with 100 already allocated
    top_up.amount = 99

    refute top_up.valid?
    assert_includes top_up.errors[:base].join, "Allocated amount exceeds"
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Metadata and delegation
  # ───────────────────────────────────────────────────────────────────────────

  test "owner is delegated through the wallet" do
    assert_equal users(:rich_user), wallets_transactions(:rich_top_up).owner
  end

  test "balance snapshots are nil when metadata lacks them" do
    assert_nil wallets_transactions(:rich_top_up).balance_before
    assert_nil wallets_transactions(:rich_top_up).balance_after
  end

  test "metadata always reads as an indifferent hash" do
    transaction = Wallets::Transaction.new

    assert_equal({}, transaction.metadata)

    transaction.metadata = nil
    assert_equal({}, transaction.metadata)

    transaction.metadata = {"a" => 1}
    assert_equal 1, transaction.metadata[:a]
  end

  test "metadata mutations survive save" do
    transaction = wallets_transactions(:rich_top_up)
    transaction.metadata[:audited] = true
    transaction.save!

    assert Wallets::Transaction.find(transaction.id).metadata[:audited]
  end

  test "non-hash metadata assignments are coerced to an empty hash" do
    transaction = Wallets::Transaction.new
    transaction.metadata = "garbage"

    assert_equal({}, transaction.metadata)
  end

  test "a nil metadata column is normalized to an empty hash on save" do
    # MySQL cannot give JSON columns a default, so records can arrive with a
    # NULL metadata column; saving must heal it without touching the getter.
    transaction = Wallets::Transaction.new(wallet: wallets_wallets(:rich_coins_wallet), amount: 5, category: "credit")
    transaction[:metadata] = nil
    transaction.save!

    assert_equal({}, Wallets::Transaction.find(transaction.id).metadata)
  end
end
