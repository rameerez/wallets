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
      metadata: {note: "Thanks for the help"}
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

  test "rejects transfers that exceed available balance when negatives are disabled" do
    sender = create_wallet(users(:new_user), asset_code: :credits, initial_balance: 10)
    recipient = create_wallet(users(:peer_user), asset_code: :credits, initial_balance: 0)

    assert_raises(Wallets::InsufficientBalance) do
      sender.transfer_to(recipient, 25, category: :gift)
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # `allow_negative_balance` parity for transfers
  # ───────────────────────────────────────────────────────────────────────────
  #
  # `wallet.debit` has always honored `Wallets.configuration.allow_negative_balance`
  # via `apply_debit`, but `wallet.transfer_to` had its own pre-check that
  # ALWAYS rejected transfers exceeding the source balance — the flag only
  # half-applied. Apps that flipped the flag on for a "convenience overdraft"
  # (e.g. ride-fare apps where passengers may briefly go negative until
  # rewards land) found their direct debits worked, but the canonical
  # transfer primitive — used to move value between users — silently still
  # required positive balance.
  #
  # Tests below cement the new contract: with `allow_negative_balance = true`,
  # transfers behave like debits — they go through, drive the source negative
  # (with the inbound credit forced to "none" expiration since the source has
  # no positive buckets to "preserve" from), and otherwise leave the rest of
  # the transfer flow untouched.

  test "transfers drive the source wallet negative when allow_negative_balance is enabled" do
    Wallets.configuration.allow_negative_balance = true

    sender = create_wallet(users(:new_user), asset_code: :credits, initial_balance: 10)
    recipient = create_wallet(users(:peer_user), asset_code: :credits, initial_balance: 0)

    transfer = sender.transfer_to(recipient, 25, category: :peer_payment)

    assert transfer.persisted?
    assert_equal 25, transfer.amount
    assert_equal(-15, sender.reload.balance, "source wallet went negative within the gem-level overdraft")
    assert_equal 25, recipient.reload.balance
    assert_equal sender.id, transfer.from_wallet_id
    assert_equal recipient.id, transfer.to_wallet_id
  end

  test "transfers from a wallet with zero balance succeed when allow_negative_balance is enabled" do
    Wallets.configuration.allow_negative_balance = true

    sender = create_wallet(users(:new_user), asset_code: :credits, initial_balance: 0)
    recipient = create_wallet(users(:peer_user), asset_code: :credits, initial_balance: 0)

    transfer = sender.transfer_to(recipient, 100, category: :peer_payment)

    assert transfer.persisted?
    assert_equal(-100, sender.reload.balance)
    assert_equal 100, recipient.reload.balance
  end

  test "transfers from an already-negative wallet keep going further negative when allow_negative_balance is enabled" do
    Wallets.configuration.allow_negative_balance = true

    sender = create_wallet(users(:new_user), asset_code: :credits, initial_balance: 0)
    recipient = create_wallet(users(:peer_user), asset_code: :credits, initial_balance: 0)
    sender.debit(50, category: :purchase)
    assert_equal(-50, sender.reload.balance)

    transfer = sender.transfer_to(recipient, 30, category: :peer_payment)

    assert transfer.persisted?
    assert_equal(-80, sender.reload.balance)
    assert_equal 30, recipient.reload.balance
  end

  test "preserve policy falls back to none when the transfer drives the source below zero" do
    # With "preserve", the gem normally allocates inbound credits across the
    # same expiration buckets the outbound debit consumed. When the source
    # has no positive buckets to consume from (or the transfer exceeds them),
    # there is nothing to preserve — falling back to "none" produces an
    # evergreen inbound credit on the receiver, which is the only honest
    # representation of "value created without a source bucket". Without
    # this fallback, `build_preserved_transfer_inbound_credit_specs` would
    # raise `InvalidTransfer` on the count mismatch.
    Wallets.configuration.allow_negative_balance = true

    sender = create_wallet(users(:new_user), asset_code: :credits, initial_balance: 0)
    recipient = create_wallet(users(:peer_user), asset_code: :credits, initial_balance: 0)

    transfer = sender.transfer_to(recipient, 40, category: :peer_payment)
    inbound = transfer.inbound_transactions.sole

    assert_equal "none", transfer.expiration_policy, "falls back to none when no positive buckets exist"
    assert_equal 40, inbound.amount
    assert_nil inbound.expires_at
  end

  test "preserve fallback hits when partial overdraft mixes positive buckets with new debt" do
    # Sender has a 30-credit positive bucket; transfers 100. The transfer
    # consumes the 30 (preserve would inherit its expiration) plus needs 70
    # more from thin air. There is no honest single expiration to assign
    # to that 70, so we collapse the inbound side to a single "none" credit
    # for the full amount.
    Wallets.configuration.allow_negative_balance = true

    sender = create_wallet(users(:new_user), asset_code: :credits, initial_balance: 0)
    recipient = create_wallet(users(:peer_user), asset_code: :credits, initial_balance: 0)
    sender.credit(30, category: :top_up, expires_at: 60.days.from_now)

    transfer = sender.transfer_to(recipient, 100, category: :peer_payment)
    inbound = transfer.inbound_transactions.sole

    assert_equal "none", transfer.expiration_policy
    assert_equal 100, inbound.amount
    assert_nil inbound.expires_at
    assert_equal(-70, sender.reload.balance)
    assert_equal 100, recipient.reload.balance
  end

  test "preserve policy still preserves expiration buckets when the transfer fits within positive balance" do
    # Sanity check — the negative-balance fallback must not regress the
    # default behavior for transfers that fit normally inside the source's
    # positive buckets. Same flag on, but the source has enough; preserve
    # works as before.
    Wallets.configuration.allow_negative_balance = true

    sender = create_wallet(users(:new_user), asset_code: :credits, initial_balance: 0)
    recipient = create_wallet(users(:peer_user), asset_code: :credits, initial_balance: 0)
    expiration = 90.days.from_now
    sender.credit(200, category: :top_up, expires_at: expiration)

    transfer = sender.transfer_to(recipient, 75, category: :peer_payment)
    inbound = transfer.inbound_transactions.sole

    assert_equal "preserve", transfer.expiration_policy
    assert_equal 75, inbound.amount
    assert_equal expiration.to_i, inbound.expires_at.to_i
  end

  test "fixed expiration policy is honored when transfer drives the source negative" do
    # If the caller chose "fixed" with an explicit expires_at, the inbound
    # credit takes that expiration regardless of source bucket coverage —
    # the user explicitly opted into a single inbound expiration, no need
    # for the preserve→none fallback.
    Wallets.configuration.allow_negative_balance = true

    sender = create_wallet(users(:new_user), asset_code: :credits, initial_balance: 0)
    recipient = create_wallet(users(:peer_user), asset_code: :credits, initial_balance: 0)
    expiration = 14.days.from_now

    transfer = sender.transfer_to(recipient, 50, category: :peer_payment, expiration_policy: :fixed, expires_at: expiration)
    inbound = transfer.inbound_transactions.sole

    assert_equal "fixed", transfer.expiration_policy
    assert_equal 50, inbound.amount
    assert_equal expiration.to_i, inbound.expires_at.to_i
    assert_equal(-50, sender.reload.balance)
  end

  test "explicit none policy is honored when transfer drives the source negative" do
    Wallets.configuration.allow_negative_balance = true

    sender = create_wallet(users(:new_user), asset_code: :credits, initial_balance: 0)
    recipient = create_wallet(users(:peer_user), asset_code: :credits, initial_balance: 0)

    transfer = sender.transfer_to(recipient, 50, category: :peer_payment, expiration_policy: :none)
    inbound = transfer.inbound_transactions.sole

    assert_equal "none", transfer.expiration_policy
    assert_nil inbound.expires_at
    assert_equal(-50, sender.reload.balance)
  end

  test "transfer that drives the source negative dispatches the transfer_completed callback" do
    Wallets.configuration.allow_negative_balance = true
    completed = []
    Wallets.configuration.on_transfer_completed { |ctx| completed << ctx }

    sender = create_wallet(users(:new_user), asset_code: :credits, initial_balance: 0)
    recipient = create_wallet(users(:peer_user), asset_code: :credits, initial_balance: 0)

    transfer = sender.transfer_to(recipient, 25, category: :peer_payment)

    assert_equal 1, completed.size
    assert_equal transfer.id, completed.first.transfer.id
    assert_equal 25, completed.first.amount
  end

  test "insufficient_balance callback does NOT fire on a successful negative-going transfer" do
    # The pre-check used to dispatch :insufficient and then raise. Now that
    # negative balances are allowed end-to-end, neither side-effect should
    # happen for a transfer that goes through. This guards against a
    # regression where the pre-check was kept but the raise was conditioned
    # — the callback would still fire for callers who installed
    # `on_insufficient_balance` for top-up nudge UX.
    Wallets.configuration.allow_negative_balance = true
    insufficient = []
    Wallets.configuration.on_insufficient_balance { |ctx| insufficient << ctx }

    sender = create_wallet(users(:new_user), asset_code: :credits, initial_balance: 0)
    recipient = create_wallet(users(:peer_user), asset_code: :credits, initial_balance: 0)

    sender.transfer_to(recipient, 25, category: :peer_payment)

    assert_empty insufficient, "successful negative-going transfer must not fire insufficient_balance"
  end

  test "insufficient_balance callback still fires when negatives are disabled and the transfer is rejected" do
    insufficient = []
    Wallets.configuration.on_insufficient_balance { |ctx| insufficient << ctx }

    sender = create_wallet(users(:new_user), asset_code: :credits, initial_balance: 10)
    recipient = create_wallet(users(:peer_user), asset_code: :credits, initial_balance: 0)

    assert_raises(Wallets::InsufficientBalance) do
      sender.transfer_to(recipient, 25, category: :peer_payment)
    end

    assert_equal 1, insufficient.size, "with the flag off the rejection path keeps its observability"
    assert_equal 25, insufficient.first.metadata[:required]
    assert_equal 10, insufficient.first.metadata[:available]
  end

  test "has_enough_balance? still reflects strict balance even when allow_negative_balance is true" do
    # `has_enough_balance?` is the opt-in pre-flight check apps use to decide
    # whether to attempt a transfer / debit at all. It intentionally keeps
    # strict semantics — overdraft is a deliberate choice the caller makes
    # by attempting the transfer; the predicate just answers "do they have
    # enough on hand?".
    Wallets.configuration.allow_negative_balance = true

    sender = create_wallet(users(:new_user), asset_code: :credits, initial_balance: 10)

    refute sender.has_enough_balance?(25)
    assert sender.has_enough_balance?(10)
  end

  test "concurrent overdraft transfers serialize through the wallet pair lock" do
    # `lock_wallet_pair!` already serialized concurrent transfers under the
    # positive-balance contract. With overdraft the lock matters more, not
    # less — two threads scanning a QR shouldn't double-debit a passenger
    # whose remaining headroom only covers one transfer. Verify the lock
    # is still acquired before the balance read used by the transfer.
    Wallets.configuration.allow_negative_balance = true
    sender = create_wallet(users(:new_user), asset_code: :credits, initial_balance: 0)
    recipient = create_wallet(users(:peer_user), asset_code: :credits, initial_balance: 0)

    lock_calls = 0
    sender.singleton_class.send(:define_method, :lock_wallet_pair!) do |other|
      lock_calls += 1
      first, second = [self, other].sort_by(&:id)
      first.lock!
      second.lock! unless first.id == second.id
    end

    sender.transfer_to(recipient, 25, category: :peer_payment)

    assert_equal 1, lock_calls
    assert_equal(-25, sender.reload.balance)
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

  # ───────────────────────────────────────────────────────────────────────────
  # transfer_to guards
  # ───────────────────────────────────────────────────────────────────────────

  test "transfer_to rejects a nil target" do
    error = assert_raises(Wallets::InvalidTransfer) do
      wallets_wallets(:rich_coins_wallet).transfer_to(nil, 10)
    end

    assert_equal "Target wallet is required", error.message
  end

  test "transfer_to rejects an unpersisted source wallet" do
    unsaved = Wallets::Wallet.new(owner: users(:new_user), asset_code: :coins)

    error = assert_raises(Wallets::InvalidTransfer) do
      unsaved.transfer_to(wallets_wallets(:peer_coins_wallet), 10)
    end

    assert_equal "Source wallet must be persisted", error.message
  end

  test "transfer_to rejects an unpersisted target wallet" do
    unsaved = Wallets::Wallet.new(owner: users(:new_user), asset_code: :coins)

    error = assert_raises(Wallets::InvalidTransfer) do
      wallets_wallets(:rich_coins_wallet).transfer_to(unsaved, 10)
    end

    assert_equal "Target wallet must be persisted", error.message
  end

  test "transfer_to rejects transferring to the same wallet" do
    wallet = wallets_wallets(:rich_coins_wallet)

    error = assert_raises(Wallets::InvalidTransfer) { wallet.transfer_to(wallet, 10) }
    assert_equal "Cannot transfer to the same wallet", error.message

    same_row = Wallets::Wallet.find(wallet.id)
    assert_raises(Wallets::InvalidTransfer) { wallet.transfer_to(same_row, 10) }
  end

  test "transfer_to validates the amount before touching the ledger" do
    source_wallet = wallets_wallets(:rich_coins_wallet)
    target_wallet = wallets_wallets(:peer_coins_wallet)

    [nil, 0, -10, 2.5].each do |bad_amount|
      assert_no_difference -> { Wallets::Transfer.count } do
        assert_raises(ArgumentError) { source_wallet.transfer_to(target_wallet, bad_amount) }
      end
    end
  end

  test "expires_at cannot be combined with preserve or none policies" do
    source_wallet = wallets_wallets(:rich_coins_wallet)
    target_wallet = wallets_wallets(:peer_coins_wallet)

    %i[preserve none].each do |policy|
      error = assert_raises(ArgumentError) do
        source_wallet.transfer_to(target_wallet, 10, expiration_policy: policy, expires_at: 1.day.from_now)
      end

      assert_includes error.message, "cannot be combined"
    end
  end

  test "transfer expiration policy falls back to preserve when config does not define one" do
    sender = create_wallet(users(:new_user), asset_code: :minimal, initial_balance: 50)
    recipient = create_wallet(users(:peer_user), asset_code: :minimal)

    minimal_config = Struct.new(:table_prefix, :allow_negative_balance, :low_balance_threshold)
      .new("wallets_", false, nil)
    Wallets::Wallet.stubs(:resolved_config).returns(minimal_config)

    transfer = sender.transfer_to(recipient, 10, category: :gift)

    assert_equal "preserve", transfer.expiration_policy
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Transfer model validations and leg queries
  # ───────────────────────────────────────────────────────────────────────────

  test "transfer model rejects an asset code that does not match the wallets" do
    transfer = Wallets::Transfer.new(
      from_wallet: wallets_wallets(:rich_coins_wallet),
      to_wallet: wallets_wallets(:peer_coins_wallet),
      asset_code: :gems,
      amount: 10,
      expiration_policy: :preserve
    )

    refute transfer.valid?
    assert_includes transfer.errors[:asset_code], "must match both wallets"
  end

  test "transfer model requires a category" do
    transfer = Wallets::Transfer.new(
      from_wallet: wallets_wallets(:rich_coins_wallet),
      to_wallet: wallets_wallets(:peer_coins_wallet),
      asset_code: :coins,
      amount: 10,
      category: nil,
      expiration_policy: :preserve
    )

    refute transfer.valid?
    assert_includes transfer.errors[:category], "can't be blank"
  end

  test "transfer model normalizes asset code and expiration policy" do
    transfer = Wallets::Transfer.new(
      from_wallet: wallets_wallets(:rich_coins_wallet),
      to_wallet: wallets_wallets(:peer_coins_wallet),
      asset_code: " COINS ",
      amount: 10,
      expiration_policy: " PRESERVE "
    )

    assert transfer.valid?
    assert_equal "coins", transfer.asset_code
    assert_equal "preserve", transfer.expiration_policy
  end

  test "inbound_transaction returns the single inbound leg when there is exactly one" do
    sender = create_wallet(users(:new_user), asset_code: :single_leg, initial_balance: 100)
    recipient = create_wallet(users(:peer_user), asset_code: :single_leg)

    transfer = sender.transfer_to(recipient, 25, category: :gift)

    assert_equal transfer.inbound_transactions.sole.id, transfer.inbound_transaction.id
    assert_equal transfer.outbound_transactions.sole.id, transfer.outbound_transaction.id
  end

  test "leg queries are empty on an unpersisted transfer" do
    transfer = Wallets::Transfer.new

    assert_empty transfer.outbound_transactions
    assert_empty transfer.inbound_transactions
    assert_nil transfer.outbound_transaction
    assert_nil transfer.inbound_transaction
  end

  test "a bare transfer is invalid without crashing the validation guards" do
    transfer = Wallets::Transfer.new

    refute transfer.valid?
    assert transfer.errors[:from_wallet].any?
    assert transfer.errors[:to_wallet].any?
    assert transfer.errors[:amount].any?
  end

  test "transfer metadata reads with indifferent access and mutations survive save" do
    sender = create_wallet(users(:new_user), asset_code: :meta_check, initial_balance: 50)
    recipient = create_wallet(users(:peer_user), asset_code: :meta_check)
    transfer = sender.transfer_to(recipient, 10, category: :gift, metadata: {"note" => "hi"})

    assert_equal "hi", transfer.metadata[:note]

    transfer.metadata[:flagged] = true
    transfer.save!

    assert Wallets::Transfer.find(transfer.id).metadata[:flagged]
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Concurrency
  # ───────────────────────────────────────────────────────────────────────────

  test "simultaneous opposing transfers serialize without deadlocking" do
    # `lock_wallet_pair!` always locks the wallet with the smaller id first,
    # so two opposing transfers (A→B and B→A) can never each hold one lock
    # while waiting on the other.
    alice = create_wallet(users(:new_user), asset_code: :duel, initial_balance: 100)
    bob = create_wallet(users(:peer_user), asset_code: :duel, initial_balance: 100)

    start_line = Queue.new
    threads = [[alice, bob], [bob, alice]].map do |from, to|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          start_line.pop
          from.class.find(from.id).transfer_to(to.class.find(to.id), 10, category: :peer_payment)
        end
      end
    end
    2.times { start_line << true }
    threads.each(&:join)

    assert_equal 100, alice.reload.balance
    assert_equal 100, bob.reload.balance
    assert_equal 2, Wallets::Transfer.where(from_wallet_id: [alice.id, bob.id]).count
  end
end
