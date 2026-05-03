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

  # ───────────────────────────────────────────────────────────────────────────
  # Negative-balance audit coverage
  # ───────────────────────────────────────────────────────────────────────────
  #
  # The full audit pass (see PR #3 description) walked every code path that
  # touches balance and found one real bug (`:depleted` callback) plus
  # several documented subtleties. The tests below pin the documented
  # behavior so future changes don't quietly regress them.

  test "compounding debits on a zero-balance wallet accumulate the unbacked deficit" do
    Wallets.configuration.allow_negative_balance = true
    wallet = create_wallet(users(:new_user), asset_code: :credits, initial_balance: 0)

    first_debit = wallet.debit(40, category: :purchase)
    second_debit = wallet.debit(30, category: :purchase)

    # Each debit's `unbacked_amount` is independent — the gem never
    # "spreads" debt across debits. With no positive buckets to consume,
    # both debits are 100% unbacked and the wallet's balance is the sum
    # of both deficits.
    assert_equal 40, first_debit.unbacked_amount
    assert_equal 30, second_debit.unbacked_amount
    assert_equal(-70, wallet.reload.balance)
  end

  test "a credit on a negative-balance wallet does not auto-allocate against existing unbacked debits" do
    # Documented behavior: the FIFO model's audit story is intentionally
    # immutable — once a debit is unbacked, the gem won't quietly back-
    # fill it from a later credit. Both ledger entries persist and the
    # `balance` accessor reconciles them on the fly. Apps that want
    # "settle the debt automatically on the next credit" should layer
    # that on top in their own service code; the gem deliberately keeps
    # the ledger append-only and unsurprising.
    Wallets.configuration.allow_negative_balance = true
    wallet = create_wallet(users(:new_user), asset_code: :credits, initial_balance: 0)
    debit = wallet.debit(50, category: :purchase)
    credit = wallet.credit(80, category: :reward)

    assert_equal 50, debit.reload.unbacked_amount, "the unbacked debit stays unbacked"
    assert_equal 80, credit.reload.remaining_amount, "the new credit is fully unspent"
    assert_equal 30, wallet.reload.balance, "balance reconciles the two sides"
  end

  test "fifo consumption pulls from the oldest non-expired positive bucket and ignores unbacked debits" do
    # Companion to the test above: walks the explicit allocation chain so
    # callers reading the audit log can see how the gem reasoned about
    # which credit covered which debit.
    Wallets.configuration.allow_negative_balance = true
    wallet = create_wallet(users(:new_user), asset_code: :credits, initial_balance: 0)
    wallet.debit(50, category: :purchase)               # 0 → -50, unbacked 50
    new_credit = wallet.credit(80, category: :reward)   # -50 → 30, credit untouched
    spend = wallet.debit(60, category: :purchase)       # 30 → -30
    spend.reload

    allocations = spend.outgoing_allocations.includes(:source_transaction).order(:id).to_a
    assert_equal 1, allocations.size, "only the new credit was used; the old unbacked debit stays unbacked"
    assert_equal new_credit.id, allocations.first.source_transaction_id
    assert_equal 60, allocations.first.amount
    assert_equal(-30, wallet.reload.balance)
  end

  test "has_enough_balance? returns false on a negative wallet for any positive amount" do
    Wallets.configuration.allow_negative_balance = true
    wallet = create_wallet(users(:new_user), asset_code: :credits, initial_balance: 0)
    wallet.debit(40, category: :purchase)

    assert_equal(-40, wallet.reload.balance)
    refute wallet.has_enough_balance?(1)
    refute wallet.has_enough_balance?(40)
    refute wallet.has_enough_balance?(0_000_000_000)
  end

  test "transactions on a negative wallet record correct balance_before and balance_after snapshots" do
    Wallets.configuration.allow_negative_balance = true
    wallet = create_wallet(users(:new_user), asset_code: :credits, initial_balance: 10)
    debit = wallet.debit(40, category: :purchase)
    credit = wallet.credit(15, category: :reward)

    assert_equal 10, debit.balance_before
    assert_equal(-30, debit.balance_after)
    assert_equal(-30, credit.balance_before)
    assert_equal(-15, credit.balance_after)
  end

  test "flipping allow_negative_balance off while a wallet is negative makes subsequent saves fail" do
    # Documented gotcha: `allow_negative_balance` is meant to be a stable
    # config decision, not a runtime toggle. The wallet model carries a
    # `balance >= 0` validation gated on the flag; flipping the flag off
    # while wallets are below zero leaves them un-saveable, which means
    # any further `credit` / `debit` (both call `refresh_cached_balance!`
    # internally, which calls `save!`) raises a validation error.
    Wallets.configuration.allow_negative_balance = true
    owner = users(:new_user)
    wallet = create_wallet(owner, asset_code: :credits, initial_balance: 0)
    wallet.debit(20, category: :purchase)
    assert_equal(-20, owner.wallet(:credits).balance)

    Wallets.configuration.allow_negative_balance = false

    # Re-fetch the wallet so the lock acquired by `with_lock` doesn't trip
    # AR's "no unpersisted changes" guard. Apps reach this branch by
    # calling `user.wallet(:foo).credit(...)` after a flag flip; this
    # mirrors that.
    error = assert_raises(ActiveRecord::RecordInvalid) do
      owner.wallet(:credits).credit(5, category: :reward)
    end
    assert_includes error.message, "Balance must be greater than or equal to 0"

    # Recovery: flip the flag back on.
    Wallets.configuration.allow_negative_balance = true
    owner.wallet(:credits).credit(5, category: :reward)
    assert_equal(-15, owner.wallet(:credits).balance)
  end

  test "concurrent debits on the same wallet serialize through with_lock and accumulate correctly" do
    # `wallet.debit` wraps `apply_debit` in `with_lock`, which acquires a
    # row-level FOR UPDATE on the wallet row. With `allow_negative_balance`
    # on, two concurrent debits should NOT both observe the same
    # `previous_balance` and double-count: they serialize, each sees the
    # post-prior-debit state, and the resulting balance is the sum.
    Wallets.configuration.allow_negative_balance = true
    wallet = create_wallet(users(:new_user), asset_code: :credits, initial_balance: 0)

    threads = 4.times.map do
      Thread.new do
        # Each thread needs its own AR connection; integration tests rely
        # on the connection-per-thread pool. Without checkout, threads
        # would share the test connection and serialize incidentally.
        ActiveRecord::Base.connection_pool.with_connection do
          wallet.class.find(wallet.id).debit(10, category: :purchase)
        end
      end
    end
    threads.each(&:join)

    assert_equal(-40, wallet.reload.balance)
    assert_equal 4, wallet.transactions.where("amount < 0").count
  end
end
