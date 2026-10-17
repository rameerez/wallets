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

  # ───────────────────────────────────────────────────────────────────────────
  # A command's savepoint decides its callbacks
  # ───────────────────────────────────────────────────────────────────────────
  #
  # Every command runs in its own savepoint and queues its success callbacks
  # on it: a failure later in the command rolls the savepoint back and drops
  # them, even when the caller rescues and commits its own transaction.

  SUCCESS_EVENTS = %i[balance_credited balance_debited transfer_completed hold_created hold_released low_balance_reached balance_depleted].freeze

  test "a transfer whose inbound leg fails leaves nothing behind and reports nothing, even when the caller rescues and commits" do
    Wallets.configuration.low_balance_threshold = 50
    sender = create_wallet(users(:new_user), asset_code: :legs, initial_balance: 100)
    recipient = create_wallet(users(:peer_user), asset_code: :legs)
    events = record(*SUCCESS_EVENTS)
    recipient.stubs(:apply_credit).raises(ActiveRecord::StatementInvalid, "the inbound leg failed")

    Wallets::Wallet.transaction do
      assert_raises(ActiveRecord::StatementInvalid) { sender.transfer_to(recipient, 60, category: :peer_payment) }
      Wallets::Wallet.find(recipient.id).balance # the caller's transaction carries on
    end

    assert_empty events, "the outbound debit and its low-balance crossing were reported"
    assert_empty Wallets::Transfer.where(from_wallet_id: sender.id)
    assert_empty sender.transactions.debits
    assert_empty Wallets::Allocation.where(source_transaction_id: sender.transactions.select(:id))
    assert_equal 100, Wallets::Wallet.find(sender.id).read_attribute(:balance), "the cached balance is untouched"
    refute sender.has_changes_to_save?, "the sender can run its next command"
    assert_equal 100, sender.debit(10, category: :purchase).balance_before
  end

  test "a credit that fails after reporting itself reports nothing, even when the caller rescues and commits" do
    wallet = create_wallet(users(:new_user), asset_code: :late_failure)
    events = record(*SUCCESS_EVENTS)
    wallet.stubs(:dispatch_hold_created!).raises(ActiveRecord::StatementInvalid, "failed after balance_credited was queued")

    Wallets::Wallet.transaction do
      assert_raises(ActiveRecord::StatementInvalid) { wallet.credit(751, category: :reward, hold: :pending_validation) }
    end

    assert_empty events
    assert_empty Wallets::Transaction.where(wallet_id: wallet.id)
  end

  test "a hold that fails after reporting itself reports nothing, even when the caller rescues and commits" do
    Wallets.configuration.low_balance_threshold = 10
    wallet = create_wallet(users(:new_user), asset_code: :late_failure, initial_balance: 100)
    events = record(*SUCCESS_EVENTS)
    wallet.stubs(:dispatch_balance_threshold_callbacks!).raises(ActiveRecord::StatementInvalid, "failed after hold_created was queued")

    Wallets::Wallet.transaction do
      # The same wallet object carries on after each failure: a rolled-back
      # command leaves it clean, never with a refreshed balance pending.
      assert_raises(ActiveRecord::StatementInvalid) { wallet.hold(category: :chargeback) }
      assert_raises(ActiveRecord::StatementInvalid) { wallet.reserve(10, category: :booking) }
      assert_raises(ActiveRecord::StatementInvalid) { wallet.debit(10, category: :purchase) }
      refute wallet.has_changes_to_save?
    end

    assert_empty events
    assert_empty Wallets::Hold.where(wallet_id: wallet.id)
    assert_empty Wallets::Transaction.where(wallet_id: wallet.id).debits
    assert_equal 100, wallet.reload.read_attribute(:balance)
  end

  test "every command's success callbacks are dropped when an enclosing transaction rolls back" do
    sender = create_wallet(users(:new_user), asset_code: :rolled_back, initial_balance: 100)
    recipient = create_wallet(users(:peer_user), asset_code: :rolled_back)
    standing = sender.hold(category: :chargeback, until: 1.day.from_now)
    events = record(*SUCCESS_EVENTS)

    Wallets::Wallet.transaction do
      standing.release!
      held = sender.credit(10, category: :reward, hold: :pending_validation)
      sender.debit(10, category: :purchase)
      sender.reserve(10, category: :booking)
      sender.reserve(10, category: :booking).capture!(category: :purchase)
      sender.debit(10, category: :purchase, from: held)
      sender.transfer_to(recipient, 10, category: :peer_payment, from: sender.transactions.credits.order(:id).first)
      sender.transfer_to(recipient, 10, category: :peer_payment)
      sender.hold(category: :chargeback)
      raise ActiveRecord::Rollback
    end

    assert_empty events
    assert Wallets::Hold.find(standing.id).active?
    assert_equal [0, 100, 0], [sender.reload.balance, sender.total_balance, recipient.reload.total_balance]
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Holds and reservations
  # ───────────────────────────────────────────────────────────────────────────

  test "hold_created reports a credit hold with its creation metadata" do
    events = record(:hold_created)
    wallet = create_wallet(users(:new_user), asset_code: :held)
    credit = wallet.credit(100, category: :reward)
    wallet.credit(50, category: :top_up)

    hold = wallet.hold(credit, category: :fraud_review, metadata: {case_id: 42})

    context = events.sole
    assert_equal :hold_created, context.event
    assert_equal hold, context.hold
    assert_same wallet, context.wallet
    assert_equal users(:new_user), context.owner
    assert_equal "fraud_review", context.category
    assert_nil context.amount, "a coverage hold has no amount"
    assert_equal 150, context.previous_balance
    assert_equal 50, context.new_balance
    assert_equal 42, context.metadata[:case_id]
    assert_nil context.transaction
    assert_equal %i[event wallet previous_balance new_balance category metadata hold].sort, context.to_h.keys.sort
  end

  test "hold_created reports a reservation with its amount" do
    events = record(:hold_created)
    wallet = create_wallet(users(:new_user), asset_code: :held, initial_balance: 100)

    reservation = wallet.reserve(30, category: :booking, metadata: {booking_id: 9})

    context = events.sole
    assert_equal reservation, context.hold
    assert_equal 30, context.amount
    assert_equal "booking", context.category
    assert_equal [100, 70], [context.previous_balance, context.new_balance]
    assert_equal 9, context.metadata[:booking_id]
  end

  test "hold_created reports a wallet hold" do
    events = record(:hold_created)
    wallet = create_wallet(users(:new_user), asset_code: :held, initial_balance: 100)

    hold = wallet.hold(category: :chargeback)

    assert_equal hold, events.sole.hold
    assert_equal [100, 0], [events.sole.previous_balance, events.sole.new_balance]
    assert_equal({}, events.sole.metadata)
  end

  test "hold_released reports the release metadata, never the creation metadata" do
    events = record(:hold_released)
    wallet = create_wallet(users(:new_user), asset_code: :held)
    credit = wallet.credit(100, category: :reward)
    hold = wallet.hold(credit, category: :fraud_review, metadata: {case_id: 42})

    hold.release!(reason: "cleared_by_operator", metadata: {actor_id: 12})

    context = events.sole
    assert_equal :hold_released, context.event
    assert_equal hold, context.hold
    assert_equal wallet, context.wallet
    assert_equal [0, 100], [context.previous_balance, context.new_balance]
    assert_equal({"actor_id" => 12}, context.metadata)
    assert_equal "cleared_by_operator", context.hold.release_reason
    assert_equal "fraud_review", context.category, "the hold's category, as on hold_created"
    assert_nil context.transaction, "only a capture names a debit"
    assert_nil context.amount, "a coverage hold has no amount"
    assert_equal %i[event wallet previous_balance new_balance category metadata hold].sort, context.to_h.keys.sort
  end

  test "hold_released reports a released reservation with its amount" do
    events = record(:hold_released)
    wallet = create_wallet(users(:new_user), asset_code: :held, initial_balance: 100)
    reservation = wallet.reserve(30, category: :booking, metadata: {booking_id: 9})

    reservation.release!(reason: "cancelled", metadata: {by: "guest"})

    context = events.sole
    assert_equal reservation, context.hold
    assert_equal 30, context.amount
    assert_equal "booking", context.category
    assert_equal [70, 100], [context.previous_balance, context.new_balance]
    assert_equal({"by" => "guest"}, context.metadata)
    assert_nil context.transaction
    assert_equal %i[event wallet amount previous_balance new_balance category metadata hold].sort, context.to_h.keys.sort
  end

  test "an idempotent release reports nothing" do
    events = record(:hold_released)
    wallet = create_wallet(users(:new_user), asset_code: :held, initial_balance: 100)
    released = wallet.hold(category: :chargeback)
    released.release!
    lapsed = wallet.hold(category: :chargeback, until: 1.day.from_now)

    travel 2.days do
      released.release!
      lapsed.release!
    end

    assert_equal 1, events.size
  end

  test "hold callbacks wait for the outermost commit" do
    events = record(:hold_created, :hold_released)
    wallet = create_wallet(users(:new_user), asset_code: :held, initial_balance: 100)

    Wallets::Wallet.transaction do
      reservation = wallet.reserve(30, category: :booking)
      wallet.hold(category: :chargeback)
      reservation.release!

      assert_empty events, "nothing is reported before the caller's transaction commits"
    end

    assert_equal %i[hold_created hold_created hold_released], events.map(&:event)
  end

  test "hold callbacks are dropped when an enclosing transaction rolls back" do
    events = record(:hold_created, :hold_released, :balance_credited)
    wallet = create_wallet(users(:new_user), asset_code: :held, initial_balance: 100)
    standing = wallet.hold(category: :chargeback)
    events.clear

    Wallets::Wallet.transaction do
      standing.release!
      wallet.reserve(30, category: :booking)
      wallet.credit(10, category: :reward, hold: :pending_validation)
      raise ActiveRecord::Rollback
    end

    assert_empty events
    assert_equal [standing.id], Wallets::Hold.where(wallet: wallet).pluck(:id)
    assert Wallets::Hold.find(standing.id).active?
  end

  test "a credit arriving held reports the finished operation, never a spendable instant" do
    events = record(:balance_credited, :hold_created, :low_balance_reached, :balance_depleted)
    Wallets.configuration.low_balance_threshold = 50
    wallet = create_wallet(users(:new_user), asset_code: :held, initial_balance: 10)
    events.clear

    credit = wallet.credit(751, category: :reward, metadata: {ride_id: 1}, hold: {category: :pending_validation, metadata: {case: "c-1"}})

    assert_equal %i[balance_credited hold_created], events.map(&:event)
    credited, created = events
    assert_equal credit, credited.transaction
    assert_equal 751, credited.amount
    assert_equal [10, 10], [credited.previous_balance, credited.new_balance]
    assert_equal 1, credited.metadata[:ride_id]
    assert_equal credit.holds.sole, created.hold
    assert_equal [10, 10], [created.previous_balance, created.new_balance]
    assert_equal "c-1", created.metadata[:case]
  end

  test "a credit that cannot get its hold reports nothing, even when the caller rescues and commits" do
    events = record(:balance_credited, :hold_created)
    wallet = create_wallet(users(:new_user), asset_code: :held)

    Wallets::Wallet.transaction do
      assert_raises(ActiveRecord::RecordInvalid) { wallet.credit(751, category: :reward, hold: {category: ""}) }
    end

    assert_empty events
  end

  test "a hold that crosses a threshold reports the crossing once" do
    events = record(:low_balance_reached, :balance_depleted)
    Wallets.configuration.low_balance_threshold = 100
    wallet = create_wallet(users(:new_user), asset_code: :held)
    held = wallet.credit(100, category: :reward)
    wallet.credit(50, category: :top_up)

    wallet.hold(held, category: :fraud_review) # 150 -> 50: low
    wallet.hold(held, category: :dispute)      # 50 -> 50: another reason moves nothing
    wallet.hold(category: :chargeback)         # 50 -> 0: depleted, already low

    assert_equal %i[low_balance_reached balance_depleted], events.map(&:event)
    assert_equal [150, 50], [events.first.previous_balance, events.first.new_balance]
    assert_equal 100, events.first.threshold
    assert_equal [50, 0], [events.second.previous_balance, events.second.new_balance]
  end

  test "a reservation that crosses both thresholds reports each once" do
    events = record(:low_balance_reached, :balance_depleted)
    Wallets.configuration.low_balance_threshold = 20
    wallet = create_wallet(users(:new_user), asset_code: :held, initial_balance: 100)

    wallet.reserve(100, category: :booking)

    assert_equal %i[low_balance_reached balance_depleted], events.map(&:event)
    assert events.all? { |context| [context.previous_balance, context.new_balance] == [100, 0] }
  end

  test "a hold over value that is already held crosses nothing" do
    events = record(:low_balance_reached, :balance_depleted)
    Wallets.configuration.low_balance_threshold = 10
    wallet = create_wallet(users(:new_user), asset_code: :held, initial_balance: 100)
    wallet.hold(category: :chargeback)
    events.clear

    wallet.hold(wallet.transactions.credits.sole, category: :fraud_review)
    wallet.credit(30, category: :reward, hold: :pending_validation)

    assert_empty events
  end

  test "a release crosses no threshold, and the next hold crosses again" do
    events = record(:low_balance_reached, :balance_depleted)
    Wallets.configuration.low_balance_threshold = 10
    wallet = create_wallet(users(:new_user), asset_code: :held, initial_balance: 100)
    hold = wallet.hold(category: :chargeback)
    assert_equal 2, events.size

    hold.release!
    assert_equal 2, events.size, "giving value back reports no threshold"

    wallet.hold(category: :chargeback)
    assert_equal 4, events.size, "a fresh crossing is reported again"
  end

  test "insufficient_balance fires immediately for a rejected reservation, naming what is held and reserved" do
    events = record(:insufficient_balance, :hold_created)
    wallet = create_wallet(users(:new_user), asset_code: :held, initial_balance: 100)
    wallet.hold(wallet.credit(50, category: :reward), category: :fraud_review)
    wallet.reserve(60, category: :booking)
    events.clear

    Wallets::Wallet.transaction do
      assert_raises(Wallets::InsufficientBalance) { wallet.reserve(41, category: :booking, metadata: {booking_id: 9}) }
      raise ActiveRecord::Rollback
    end

    context = events.sole
    assert_equal :insufficient_balance, context.event
    assert_equal 41, context.amount
    assert_equal [40, 40], [context.previous_balance, context.new_balance]
    assert_equal({available: 40, required: 41, held: 50, reserved: 60, booking_id: 9}, context.metadata.symbolize_keys)
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Capture
  # ───────────────────────────────────────────────────────────────────────────

  test "a capture reports one debit and one release, the release naming the debit" do
    events = record(:balance_debited, :hold_released, :hold_created)
    wallet = create_wallet(users(:new_user), asset_code: :captured, initial_balance: 100)
    reservation = wallet.reserve(50, category: :booking, metadata: {booking_id: 9})
    events.clear

    debit = reservation.capture!(30, category: :purchase, metadata: {order: "o-1"})

    assert_equal %i[balance_debited hold_released], events.map(&:event)
    debited, released = events
    assert_equal debit, debited.transaction
    assert_equal 30, debited.amount
    assert_equal :purchase, debited.category
    assert_equal [50, 70], [debited.previous_balance, debited.new_balance]
    assert_equal "o-1", debited.metadata[:order]

    assert_equal reservation, released.hold
    assert_same wallet, released.wallet
    assert_equal debit, released.transaction, "the capture debit is reached from the release"
    assert_equal [50, 70], [released.previous_balance, released.new_balance]
    assert_equal({}, released.metadata, "the capture's metadata lives on the debit, never duplicated on the hold")
    assert_equal "captured", released.hold.release_reason
    assert_equal 50, released.amount, "the reservation's own amount, as on hold_created; the debit carries what was captured"
    assert_equal "booking", released.category
    assert_equal %i[event wallet amount category previous_balance new_balance transaction metadata hold].sort, released.to_h.keys.sort
  end

  test "a whole capture of a fully reserved wallet reports 0 -> 0 and crosses no threshold" do
    events = record(:balance_debited, :hold_released, :low_balance_reached, :balance_depleted)
    Wallets.configuration.low_balance_threshold = 50
    wallet = create_wallet(users(:new_user), asset_code: :captured, initial_balance: 100)
    reservation = wallet.reserve(100, category: :booking)
    assert_equal %i[low_balance_reached balance_depleted], events.map(&:event), "the reservation itself crossed both"
    events.clear

    reservation.capture!(category: :purchase)

    assert_equal %i[balance_debited hold_released], events.map(&:event), "no threshold was crossed: available never moved"
    assert events.all? { |context| [context.previous_balance, context.new_balance] == [0, 0] }
  end

  test "a rejected capture reports insufficient_balance at once, with the balance nothing moved and what the capture could draw on" do
    events = record(:insufficient_balance, :balance_debited, :hold_released)
    wallet = create_wallet(users(:new_user), asset_code: :captured, initial_balance: 100)
    reservation = wallet.reserve(80, category: :booking)
    wallet.hold(category: :chargeback)

    Wallets::Wallet.transaction do
      assert_raises(Wallets::InsufficientBalance) { reservation.capture!(category: :purchase, metadata: {booking_id: 9}) }
      raise ActiveRecord::Rollback
    end

    context = events.sole
    assert_equal :insufficient_balance, context.event
    assert_equal 80, context.amount
    assert_equal [-80, -80], [context.previous_balance, context.new_balance], "the original balance, never an intermediate one"
    assert_equal({available: -80, required: 80, held: 100, reserved: 80, available_for_capture: 0, booking_id: 9}, context.metadata.symbolize_keys)
    assert reservation.reload.active?
  end

  test "a capture that fails after reporting itself reports nothing, even when the caller rescues and commits" do
    wallet = create_wallet(users(:new_user), asset_code: :late_failure, initial_balance: 100)
    reservation = wallet.reserve(30, category: :booking)
    events = record(*SUCCESS_EVENTS)
    reservation.wallet.stubs(:dispatch_balance_threshold_callbacks!).raises(ActiveRecord::StatementInvalid, "failed after debited and hold_released were queued")

    Wallets::Wallet.transaction do
      assert_raises(ActiveRecord::StatementInvalid) { reservation.capture!(category: :purchase) }
    end

    assert_empty events
    assert Wallets::Hold.find(reservation.id).active?
    assert_empty wallet.transactions.debits
  end

  test "capture callbacks wait for the outermost commit" do
    events = record(:balance_debited, :hold_released)
    wallet = create_wallet(users(:new_user), asset_code: :captured, initial_balance: 100)
    reservation = wallet.reserve(30, category: :booking)

    Wallets::Wallet.transaction do
      reservation.capture!(category: :purchase)
      assert_empty events, "nothing is reported before the caller's transaction commits"
    end

    assert_equal %i[balance_debited hold_released], events.map(&:event)
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Targeted debits
  # ───────────────────────────────────────────────────────────────────────────

  test "cancelling held value reports a debit and releases nothing" do
    events = record(:balance_debited, :hold_released, :low_balance_reached, :balance_depleted)
    Wallets.configuration.low_balance_threshold = 50
    wallet = create_wallet(users(:new_user), asset_code: :targeted)
    credit = wallet.credit(751, category: :reward, hold: :pending_validation)
    events.clear

    debit = wallet.debit(751, category: :purchase, from: credit, metadata: {reason: "reward_rejected"})

    context = events.sole
    assert_equal :balance_debited, context.event
    assert_equal debit, context.transaction
    assert_equal 751, context.amount
    assert_equal [0, 0], [context.previous_balance, context.new_balance]
    assert_equal "reward_rejected", context.metadata[:reason]
    assert_equal [0, 0], [debit.balance_before, debit.balance_after]
  end

  test "a targeted debit crosses thresholds like any debit, from its original and final balances" do
    events = record(:low_balance_reached, :balance_depleted)
    Wallets.configuration.low_balance_threshold = 50
    wallet = create_wallet(users(:new_user), asset_code: :targeted)
    free = wallet.credit(100, category: :top_up)
    held = wallet.credit(100, category: :reward, hold: :fraud_review)

    wallet.debit(60, category: :purchase, from: free)   # 100 -> 40: low
    wallet.debit(100, category: :purchase, from: held)  # 40 -> 40: nothing
    wallet.debit(40, category: :purchase, from: free)   # 40 -> 0: depleted, already low

    assert_equal %i[low_balance_reached balance_depleted], events.map(&:event)
    assert_equal [[100, 40], [40, 0]], events.map { |context| [context.previous_balance, context.new_balance] }
  end

  test "insufficient_balance for a targeted debit names the held value it would have taken" do
    events = record(:insufficient_balance, :balance_debited, :transfer_completed)
    wallet = create_wallet(users(:new_user), asset_code: :targeted)
    held = wallet.credit(50, category: :reward, hold: :fraud_review)
    free = wallet.credit(100, category: :top_up)
    wallet.reserve(90, category: :booking)
    recipient = create_wallet(users(:peer_user), asset_code: :targeted)

    assert_raises(Wallets::InsufficientBalance) { wallet.debit(61, category: :purchase, from: [held, free], metadata: {case_id: 7}) }
    assert_raises(Wallets::InsufficientBalance) { wallet.transfer_to(recipient, 151, category: :peer_payment, from: [held, free]) }

    shortfall, short_sources = events
    assert_equal 2, events.size, "once per refusal, and nothing else"
    assert_equal({available: 10, required: 61, held: 50, reserved: 90, covered_consumed: 50, case_id: 7}, shortfall.metadata.symbolize_keys)
    assert_equal [10, 10], [shortfall.previous_balance, shortfall.new_balance]
    assert_equal({available: 10, required: 151, held: 50, reserved: 90, covered_consumed: 50}, short_sources.metadata.symbolize_keys)
  end

  test "a ledger may leave hold events unmapped" do
    silent = Class.new(Wallets::Wallet) do
      def self.name
        "SilentHoldsWallet"
      end

      self.callback_event_map = callback_event_map.merge(hold_created: nil, hold_released: nil).freeze
    end
    events = record(:hold_created, :hold_released)
    wallet = silent.find(create_wallet(users(:new_user), asset_code: :held, initial_balance: 100).id)

    wallet.hold(category: :chargeback).release!

    assert_empty events
    assert_equal 100, wallet.balance
  end

  private

  # Every context dispatched for the given events, in order.
  def record(*events)
    contexts = []
    events.each { |event| Wallets.configuration.public_send(:"on_#{event}") { |context| contexts << context } }
    contexts
  end
end
