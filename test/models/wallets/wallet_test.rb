# frozen_string_literal: true

require "test_helper"

class Wallets::WalletTest < ActiveSupport::TestCase
  test "computes balance from non-expired positive transactions minus allocations" do
    wallet = wallets_wallets(:rich_coins_wallet)

    assert_equal 1000, wallet.balance
  end

  test "credit creates a transaction and updates balance snapshots" do
    wallet = wallets_wallets(:rich_coins_wallet)

    transaction = wallet.credit(75, category: :reward, metadata: {source: "promo"})

    assert_equal 75, transaction.amount
    assert_equal 1000, transaction.balance_before
    assert_equal 1075, transaction.balance_after
    assert_equal 1075, wallet.reload.balance
  end

  test "public transaction keywords cannot override ledger accounting fields" do
    wallet = create_wallet(users(:new_user), asset_code: :protected_attributes, initial_balance: 100)

    error = assert_raises(ArgumentError) do
      wallet.credit(10, amount: -1_000, category: :reward)
    end
    assert_includes error.message, "Unsupported transaction attributes: amount"

    error = assert_raises(ArgumentError) do
      wallet.debit(10, created_at: 10.years.ago, category: :purchase)
    end
    assert_includes error.message, "Unsupported transaction attributes: created_at"

    assert_equal 100, wallet.reload.balance
    assert_equal 1, wallet.transactions.count
  end

  test "debit allocates from the oldest available transactions first" do
    wallet = create_wallet(users(:new_user), asset_code: :wood, initial_balance: 0)

    oldest = wallet.credit(100, category: :top_up, metadata: {bucket: "oldest"})
    newer = wallet.credit(80, category: :reward, metadata: {bucket: "newer"})

    spend = wallet.debit(130, category: :purchase, metadata: {sku: "bundle"})
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

  # ───────────────────────────────────────────────────────────────────────────
  # Balance, expiration, and FIFO order
  # ───────────────────────────────────────────────────────────────────────────

  test "balance excludes credits once they expire" do
    wallet = create_wallet(users(:new_user), asset_code: :promo)
    wallet.credit(100, category: :reward, expires_at: 2.days.from_now)
    wallet.credit(40, category: :top_up)

    assert_equal 140, wallet.balance

    travel 3.days do
      assert_equal 40, wallet.balance
    end
  end

  test "debit consumes the soonest-expiring bucket before older evergreen credits" do
    wallet = create_wallet(users(:new_user), asset_code: :data)
    evergreen = wallet.credit(100, category: :top_up)
    expiring = wallet.credit(50, category: :reward, expires_at: 2.days.from_now)

    spend = wallet.debit(60, category: :purchase)
    allocations = spend.outgoing_allocations.order(:id)

    assert_equal expiring.id, allocations.first.source_transaction_id, "expiring value is spent first"
    assert_equal 50, allocations.first.amount
    assert_equal evergreen.id, allocations.second.source_transaction_id
    assert_equal 10, allocations.second.amount
  end

  test "debit never allocates from expired buckets" do
    wallet = create_wallet(users(:new_user), asset_code: :stale)
    expiring = wallet.credit(100, category: :reward, expires_at: 1.day.from_now)
    evergreen = wallet.credit(50, category: :top_up)

    travel 2.days do
      spend = wallet.debit(30, category: :purchase)

      assert_equal [evergreen.id], spend.outgoing_allocations.pluck(:source_transaction_id)
      assert_equal 0, expiring.reload.allocated_amount
      assert_equal 20, wallet.balance
    end
  end

  test "debit can empty the wallet exactly to zero" do
    wallet = create_wallet(users(:new_user), asset_code: :exact, initial_balance: 75)

    spend = wallet.debit(75, category: :purchase)

    assert_equal 0, wallet.reload.balance
    assert_equal(-75, spend.amount)
    assert_equal 0, spend.unbacked_amount
  end

  test "history orders transactions chronologically with id as tiebreaker" do
    wallet = create_wallet(users(:new_user), asset_code: :hist)
    ids = freeze_time do
      3.times.map { |i| wallet.credit(10 + i, category: :top_up).id }
    end

    assert_equal ids, wallet.history.where(id: ids).pluck(:id)
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Amount validation edges
  # ───────────────────────────────────────────────────────────────────────────

  test "credit and debit reject invalid amounts with ArgumentError" do
    wallet = wallets_wallets(:rich_coins_wallet)

    [nil, 0, -5, 10.5, "10", :ten, Float::INFINITY, Float::NAN].each do |bad_amount|
      assert_raises(ArgumentError, "credit(#{bad_amount.inspect}) should raise") { wallet.credit(bad_amount) }
      assert_raises(ArgumentError, "debit(#{bad_amount.inspect}) should raise") { wallet.debit(bad_amount) }
    end
  end

  test "whole-number floats are accepted and stored as integers" do
    wallet = create_wallet(users(:new_user), asset_code: :floaty)

    transaction = wallet.credit(10.0, category: :top_up)

    assert_equal 10, transaction.amount
    assert_equal 10, wallet.reload.balance
  end

  test "has_enough_balance? handles edge inputs gracefully" do
    wallet = wallets_wallets(:rich_coins_wallet) # balance 1000

    assert wallet.has_enough_balance?(1000)
    assert wallet.has_enough_balance?(999.0)
    refute wallet.has_enough_balance?(1001)
    refute wallet.has_enough_balance?(nil)
    refute wallet.has_enough_balance?(0)
    refute wallet.has_enough_balance?(-5)
    refute wallet.has_enough_balance?(10.5)
    refute wallet.has_enough_balance?(:lots)
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Expiration validation
  # ───────────────────────────────────────────────────────────────────────────

  test "credit rejects past expirations" do
    wallet = wallets_wallets(:rich_coins_wallet)

    error = assert_raises(ArgumentError) { wallet.credit(10, expires_at: 1.hour.ago) }
    assert_includes error.message, "future"
  end

  test "credit rejects non-temporal expirations" do
    wallet = wallets_wallets(:rich_coins_wallet)

    assert_raises(ArgumentError) { wallet.credit(10, expires_at: 123) }
    assert_raises(ArgumentError) { wallet.credit(10, expires_at: "not a date") }
  end

  test "credit accepts a Date and a parseable String as expiration" do
    wallet = create_wallet(users(:new_user), asset_code: :seasonal)

    from_date = wallet.credit(10, category: :reward, expires_at: Date.tomorrow)
    from_string = wallet.credit(10, category: :reward, expires_at: 2.days.from_now.iso8601)

    assert_equal Date.tomorrow, from_date.expires_at.to_date
    assert from_string.expires_at.future?
  end

  # ───────────────────────────────────────────────────────────────────────────
  # create_for_owner! race and conflict paths
  # ───────────────────────────────────────────────────────────────────────────

  test "create_for_owner returns the winner's wallet when losing a duplicate-insert race" do
    owner = users(:new_user)
    existing = create_wallet(owner, asset_code: :raced)

    Wallets::Wallet.stubs(:find_by).returns(nil).then.returns(existing)
    Wallets::Wallet.stubs(:create!).raises(ActiveRecord::RecordNotUnique.new("duplicate key"))

    assert_equal existing.id, Wallets::Wallet.create_for_owner!(owner: owner, asset_code: :raced).id
  end

  test "create_for_owner re-raises duplicate-insert errors when no wallet actually exists" do
    Wallets::Wallet.stubs(:create!).raises(ActiveRecord::RecordNotUnique.new("duplicate key"))

    assert_raises(ActiveRecord::RecordNotUnique) do
      Wallets::Wallet.create_for_owner!(owner: users(:new_user), asset_code: :ghost_asset)
    end
  end

  test "create_for_owner re-raises validation failures unrelated to the uniqueness conflict" do
    invalid_record = Wallets::Wallet.new
    invalid_record.errors.add(:balance, :invalid)
    Wallets::Wallet.stubs(:create!).raises(ActiveRecord::RecordInvalid.new(invalid_record))

    assert_raises(ActiveRecord::RecordInvalid) do
      Wallets::Wallet.create_for_owner!(owner: users(:new_user), asset_code: :broken_asset)
    end
  end

  test "create_for_owner survives a real duplicate insert inside a caller's transaction" do
    # This is the exact shape of the production race: the uniqueness
    # validation misses a concurrent row, the INSERT hits the unique index
    # for real, and all of it happens inside the caller's transaction (like
    # `after_create` wallet auto-creation). On PostgreSQL a unique-index
    # violation aborts the transaction it ran in, so recovering requires the
    # gem to write through a savepoint and rescue outside of it.
    owner = users(:new_user)
    existing = create_wallet(owner, asset_code: :hard_race)

    Wallets::Wallet.define_singleton_method(:create!) do |**attributes|
      record = new(**attributes)
      record.save!(validate: false) # skip the uniqueness SELECT, hit the index
      record
    end

    begin
      result = nil
      ActiveRecord::Base.transaction do
        result = Wallets::Wallet.create_for_owner!(owner: owner, asset_code: :hard_race)
        assert User.count.positive?, "outer transaction must remain usable after the rescued conflict"
      end

      assert_equal existing.id, result.id
    ensure
      Wallets::Wallet.singleton_class.send(:remove_method, :create!)
    end
  end

  test "create_for_owner normalizes asset codes and persists metadata" do
    wallet = Wallets::Wallet.create_for_owner!(
      owner: users(:new_user),
      asset_code: " EUR ",
      metadata: {"tier" => "vip"}
    )

    assert_equal "eur", wallet.asset_code
    assert_equal "vip", wallet.reload.metadata[:tier]
  end

  test "create_for_owner rejects blank and fractional inputs" do
    owner = users(:new_user)

    assert_raises(ArgumentError) { Wallets::Wallet.create_for_owner!(owner: owner, asset_code: "   ") }
    assert_raises(ArgumentError) { Wallets::Wallet.create_for_owner!(owner: owner, asset_code: :ok, initial_balance: 10.5) }
    assert_raises(ArgumentError) { Wallets::Wallet.create_for_owner!(owner: owner, asset_code: :ok, initial_balance: Float::INFINITY) }
  end

  test "create_for_owner treats a nil initial balance as zero and coerces non-hash metadata" do
    wallet = Wallets::Wallet.create_for_owner!(
      owner: users(:new_user),
      asset_code: :lenient,
      initial_balance: nil,
      metadata: "not a hash"
    )

    assert_equal 0, wallet.balance
    assert_equal({}, wallet.metadata)
    assert_empty wallet.transactions, "no seed credit is written for a zero initial balance"
  end

  test "credit and debit coerce non-hash metadata to an empty hash" do
    wallet = create_wallet(users(:new_user), asset_code: :tolerant, initial_balance: 50)

    credit = wallet.credit(10, category: :reward, metadata: "not a hash")
    debit = wallet.debit(5, category: :purchase, metadata: 42)

    assert_equal %w[balance_after balance_before], credit.metadata.keys.sort
    assert_equal %w[balance_after balance_before], debit.metadata.keys.sort
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Wallet validations and metadata
  # ───────────────────────────────────────────────────────────────────────────

  test "duplicate wallets for the same owner and asset are invalid" do
    existing = wallets_wallets(:rich_coins_wallet)
    duplicate = Wallets::Wallet.new(owner: existing.owner, asset_code: "coins", balance: 0)

    refute duplicate.valid?
    assert duplicate.errors.of_kind?(:asset_code, :taken)
  end

  test "wallet requires a present asset code and an integer balance" do
    wallet = Wallets::Wallet.new(owner: users(:new_user), asset_code: "   ", balance: 1.5)

    refute wallet.valid?
    assert wallet.errors[:asset_code].any?
    assert wallet.errors[:balance].any?
  end

  test "wallet asset codes are normalized before validation" do
    wallet = Wallets::Wallet.create!(owner: users(:new_user), asset_code: " GOLD ", balance: 0)

    assert_equal "gold", wallet.asset_code
  end

  test "wallet metadata reads with indifferent access and mutations survive save" do
    wallet = Wallets::Wallet.create_for_owner!(owner: users(:new_user), asset_code: :meta, metadata: {"tier" => "vip"})

    assert_equal "vip", wallet.metadata[:tier]

    wallet.metadata[:flag] = true
    wallet.save!
    assert Wallets::Wallet.find(wallet.id).metadata[:flag]

    wallet.metadata = nil
    assert_equal({}, wallet.metadata)
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Allocation safety net
  # ───────────────────────────────────────────────────────────────────────────

  test "debit raises when allocations cannot cover the amount even after the balance check" do
    # Safety net for the rare race where a bucket expires between the
    # balance pre-check and the FIFO allocation query.
    wallet = create_wallet(users(:new_user), asset_code: :race_guard, initial_balance: 100)
    wallet.stubs(:allocate_debit!).returns(25)

    error = assert_raises(Wallets::InsufficientBalance) { wallet.debit(50, category: :purchase) }
    assert_includes error.message, "balance buckets"
  end

  test "preserve refuses to fabricate inbound credits when allocations do not cover the amount" do
    # Deep safety net: if the FIFO allocation invariant ever broke mid-transfer,
    # the receiver must not be credited buckets that do not add up.
    wallet = wallets_wallets(:rich_coins_wallet)
    transfer = stub(id: 42)
    allocation = stub(amount: 30, source_transaction: stub(expires_at: nil))
    outbound = stub(outgoing_allocations: stub(includes: stub(order: stub(to_a: [allocation]))))

    error = assert_raises(Wallets::InvalidTransfer) do
      wallet.send(:build_preserved_transfer_inbound_credit_specs, transfer, outbound, 100)
    end

    assert_includes error.message, "could not preserve expiration buckets"
  end

  test "inbound credit specs reject policies that slipped past resolution" do
    wallet = wallets_wallets(:rich_coins_wallet)

    assert_raises(ArgumentError) do
      wallet.send(
        :build_transfer_inbound_credit_specs,
        transfer: nil, outbound_transaction: nil, amount: 10,
        expiration_policy: "bogus", expires_at: nil
      )
    end
  end

  test "lock_wallet_pair! locks the same row only once when handed twin instances" do
    wallet = wallets_wallets(:rich_coins_wallet)
    twin = Wallets::Wallet.find(wallet.id)

    ActiveRecord::Base.transaction do
      assert_nothing_raised { wallet.send(:lock_wallet_pair!, twin) }
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Destroy semantics
  # ───────────────────────────────────────────────────────────────────────────

  test "destroying a wallet with outgoing transfer history preserves the counterparty's ledger" do
    sender_owner = User.create!(email: "dst-a-#{SecureRandom.hex(4)}@example.com", name: "A")
    receiver_owner = User.create!(email: "dst-b-#{SecureRandom.hex(4)}@example.com", name: "B")
    sender = sender_owner.wallet(:coins)
    receiver = receiver_owner.wallet(:coins)
    sender.credit(100, category: :top_up)
    transfer = sender.transfer_to(receiver, 40, category: :peer_payment)
    transfer_id = transfer.id

    assert_difference -> { Wallets::Transfer.count }, -1 do
      sender.destroy!
    end

    inbound = receiver.transactions.credits.sole
    assert_equal 40, receiver.reload.balance, "the receiver keeps the transferred value"
    assert_nil inbound.reload.transfer_id, "the link object is gone"
    assert_equal transfer_id, inbound.metadata[:transfer_id], "metadata still records the transfer for audit"
  end

  test "destroying the receiving wallet keeps the sender's ledger intact" do
    sender_owner = User.create!(email: "dst-c-#{SecureRandom.hex(4)}@example.com", name: "C")
    receiver_owner = User.create!(email: "dst-d-#{SecureRandom.hex(4)}@example.com", name: "D")
    sender = sender_owner.wallet(:coins)
    receiver = receiver_owner.wallet(:coins)
    sender.credit(100, category: :top_up)
    sender.transfer_to(receiver, 40, category: :peer_payment)

    receiver.destroy!

    outbound = sender.transactions.debits.sole
    assert_nil outbound.reload.transfer_id
    assert_equal 60, sender.reload.balance
  end

  test "destroying an owner removes their wallets, transactions, and allocations" do
    owner = User.create!(email: "cascade-#{SecureRandom.hex(4)}@example.com", name: "Cascade")
    wallet = owner.wallet(:coins)
    wallet.credit(30, category: :top_up)
    wallet.debit(10, category: :purchase)
    wallet_id = wallet.id

    owner.destroy!

    assert_empty Wallets::Wallet.where(id: wallet_id)
    assert_empty Wallets::Transaction.where(wallet_id: wallet_id)
  end
end
