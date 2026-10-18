# frozen_string_literal: true

require "test_helper"

# `Hold#capture!`: a reservation turned into a posted debit in one step. The
# reservation ends as "captured", linked to the debit, and the balances the
# debit records are the ones before and after the whole step. Its callbacks
# are pinned in WalletCallbacksTest, its races in CurrentReadsTest.
class Wallets::ReservationCaptureTest < ActiveSupport::TestCase
  setup do
    @owner = users(:new_user)
    Wallets.configuration.additional_categories = Wallets.configuration.additional_categories + %w[booking_charge]
  end

  # ───────────────────────────────────────────────────────────────────────────
  # A capture
  # ───────────────────────────────────────────────────────────────────────────

  test "capturing a whole reservation posts its debit and ends the reservation, 0 -> 0" do
    freeze_time
    wallet = points_wallet(100)
    credit = wallet.transactions.credits.sole
    reservation = wallet.reserve(100, category: :booking, until: 7.days.from_now, metadata: {booking_id: 9})
    assert_equal [0, 100, 100], balances(wallet)

    debit = reservation.capture!(category: :booking_charge, metadata: {booking_id: 9})

    assert_instance_of Wallets::Transaction, debit
    assert debit.persisted?
    assert_equal(-100, debit.amount, "the amount defaults to the reserved amount")
    assert_equal "booking_charge", debit.category
    assert_equal wallet, debit.wallet
    assert_equal [[credit.id, 100]], allocations(debit)
    assert_equal 0, debit.unbacked_amount
    assert_equal [0, 0], [debit.balance_before, debit.balance_after], "no fictitious spendable instant"
    assert_equal 9, debit.metadata[:booking_id]

    assert_same debit, reservation.capture_transaction
    reservation.reload
    assert_equal debit, reservation.capture_transaction
    assert_equal reservation, debit.reload.captured_reservation
    assert reservation.captured?
    assert reservation.released?
    refute reservation.active?
    refute reservation.lapsed?
    assert_equal "captured", reservation.release_reason
    assert_equal Time.current, reservation.released_at
    assert_equal 100, reservation.amount, "the reserved amount is a creation fact, never rewritten"
    assert_equal({}, reservation.release_metadata, "the capture's metadata lives on the debit")
    assert_equal({"booking_id" => 9}, reservation.metadata)

    assert_equal [0, 0, 0], balances(wallet)
    assert_equal 0, wallet.reload.read_attribute(:balance)
  end

  test "a smaller capture releases the whole remainder" do
    wallet = points_wallet(100)
    reservation = wallet.reserve(50, category: :booking)

    debit = reservation.capture!(30, category: :booking_charge)

    assert_equal(-30, debit.amount)
    assert_equal [50, 70], [debit.balance_before, debit.balance_after]
    assert_equal [70, 0, 70], balances(wallet), "nothing stays reserved"
    assert reservation.reload.captured?
    assert_equal 50, reservation.amount
    assert_empty wallet.holds.reservations.active
  end

  test "a capture accepts any whole amount up to the reservation, parsed like a debit's" do
    wallet = points_wallet(100)

    assert_equal(-30, wallet.reserve(30, category: :booking).capture!(category: :booking_charge).amount)
    assert_equal(-25, wallet.reserve(30, category: :booking).capture!(25.0, category: :booking_charge).amount)
    assert_equal(-1, wallet.reserve(30, category: :booking).capture!(1, category: :booking_charge).amount)
    assert_equal [44, 0, 44], balances(wallet)
  end

  # Zero, negative, fractional, non-numeric, infinite, and more than the 30
  # the reservations below set aside.
  WRONG_CAPTURE_AMOUNTS = [0, -5, 1.5, "ten", Float::INFINITY, 31].freeze

  test "a capture amount above the reservation, or not a positive whole number, is refused before anything is written" do
    wallet = points_wallet(100)
    reservation = wallet.reserve(30, category: :booking)

    error = assert_nothing_written(wallet) do
      assert_raises(ArgumentError) { reservation.capture!(31, category: :booking_charge) }
    end
    assert_equal "Cannot capture 31: reservation #{reservation.id} sets aside 30", error.message

    WRONG_CAPTURE_AMOUNTS.each do |amount|
      assert_nothing_written(wallet) do
        assert_raises(ArgumentError, "amount #{amount.inspect} must be refused") { reservation.capture!(amount, category: :booking_charge) }
      end
    end
    assert reservation.reload.active?
    assert_equal [70, 30, 100], balances(wallet)
  end

  test "retrying a finished capture raises InvalidHold whatever amount it repeats" do
    # The state is checked before the amount, so a retry handler that
    # rescues InvalidHold sees every retry of a finished capture, never an
    # ArgumentError about an amount that no longer matters.
    freeze_time
    wallet = points_wallet(100)
    captured = wallet.reserve(30, category: :booking)
    captured.capture!(category: :booking_charge)
    released = wallet.reserve(30, category: :booking)
    released.release!(reason: "cancelled")
    lapsed = wallet.reserve(30, category: :booking, until: 1.hour.from_now)
    travel 1.hour

    {captured: [captured, /was already captured/], released: [released, /was released/], lapsed: [lapsed, /lapsed at/]}.each do |state, (reservation, message)|
      WRONG_CAPTURE_AMOUNTS.each do |amount|
        error = assert_nothing_written(wallet) do
          assert_raises(Wallets::InvalidHold, "a #{state} reservation with #{amount.inspect}") { reservation.capture!(amount, category: :booking_charge) }
        end
        assert_match message, error.message
      end
    end
  end

  test "a capture needs a category, and an unknown one leaves the reservation untouched" do
    wallet = points_wallet(100)
    reservation = wallet.reserve(30, category: :booking)

    assert_raises(ArgumentError) { reservation.capture! } # missing keyword
    assert_nothing_written(wallet) do
      assert_raises(ActiveRecord::RecordInvalid) { reservation.capture!(category: :not_a_category) }
    end

    assert Wallets::Hold.find(reservation.id).active?
    refute reservation.captured?
  end

  test "capture metadata is normalized like every other ledger metadata" do
    wallet = points_wallet(100)

    debit = wallet.reserve(30, category: :booking).capture!(category: :booking_charge, metadata: nil)

    assert_equal({}, debit.metadata.except("balance_before", "balance_after"))
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Only an active reservation, once
  # ───────────────────────────────────────────────────────────────────────────

  test "a second capture raises and creates nothing" do
    wallet = points_wallet(100)
    reservation = wallet.reserve(30, category: :booking)
    debit = reservation.capture!(category: :booking_charge)
    captured = Wallets::Hold.find(reservation.id).attributes

    [reservation, Wallets::Hold.find(reservation.id)].each do |copy|
      error = assert_nothing_written(wallet) do
        assert_raises(Wallets::InvalidHold) { copy.capture!(category: :booking_charge) }
      end
      assert_equal "Reservation #{reservation.id} was already captured (transaction #{debit.id})", error.message
    end
    assert_equal captured, Wallets::Hold.find(reservation.id).attributes
  end

  test "a released reservation cannot be captured" do
    wallet = points_wallet(100)
    reservation = wallet.reserve(30, category: :booking)
    reservation.release!(reason: "cancelled")

    error = assert_nothing_written(wallet) do
      assert_raises(Wallets::InvalidHold) { reservation.capture!(category: :booking_charge) }
    end

    assert_equal "Reservation #{reservation.id} was released and can no longer be captured", error.message
    assert_equal "cancelled", reservation.reload.release_reason
  end

  test "a released reservation cannot be captured through a copy that still reads active" do
    wallet = points_wallet(100)
    reservation = wallet.reserve(30, category: :booking)
    Wallets::Hold.find(reservation.id).release!(reason: "elsewhere")

    assert_raises(Wallets::InvalidHold) { reservation.capture!(category: :booking_charge) }
    assert_equal "elsewhere", reservation.release_reason, "the caller's copy shows what happened"
  end

  test "a lapsed reservation cannot be captured, from the exact instant of its deadline" do
    freeze_time
    wallet = points_wallet(100)
    reservation = wallet.reserve(30, category: :booking, until: 1.day.from_now)
    deadline = reservation.releases_at

    travel_to(deadline) do
      error = assert_nothing_written(wallet) do
        assert_raises(Wallets::InvalidHold) { reservation.capture!(category: :booking_charge) }
      end
      assert_equal "Reservation #{reservation.id} lapsed at #{deadline.iso8601} and can no longer be captured", error.message
      assert reservation.reload.lapsed?
    end

    travel_to(deadline - 1.second) do
      assert reservation.capture!(category: :booking_charge).persisted?
    end
  end

  test "a capture decides the deadline at the instant it sampled under the lock" do
    travel_to Time.utc(2030, 1, 1, 12)
    wallet = points_wallet(100)
    reservation = wallet.reserve(30, category: :booking, until: 10.seconds.from_now)
    sampled = Time.current
    Time.stubs(:current).returns(sampled).then.returns(sampled + 1.minute)

    reservation.capture!(category: :booking_charge)

    assert_equal sampled, reservation.reload.released_at
    assert reservation.captured?, "active at the sampled instant, so captured rather than lapsed"
  end

  test "only a reservation can be captured" do
    wallet = points_wallet(100)
    credit_hold = wallet.hold(wallet.transactions.credits.sole, category: :fraud_review)
    wallet_hold = wallet.hold(category: :chargeback)

    [credit_hold, wallet_hold].each do |hold|
      error = assert_nothing_written(wallet) do
        assert_raises(Wallets::InvalidHold) { hold.capture!(category: :booking_charge) }
      end
      assert_equal "Hold #{hold.id} holds credit value: only a reservation can be captured", error.message
      assert hold.reload.active?
    end
  end

  test "only a saved reservation can be captured" do
    reservation = Wallets::Hold.new(wallet: points_wallet(100), amount: 10, category: :booking)

    error = assert_raises(Wallets::InvalidHold) { reservation.capture!(category: :booking_charge) }
    assert_equal "Only a saved reservation can be captured", error.message
  end

  test "release! after a capture is a no-op that keeps the capture" do
    freeze_time
    wallet = points_wallet(100)
    reservation = wallet.reserve(30, category: :booking)
    debit = reservation.capture!(category: :booking_charge)
    captured = Wallets::Hold.find(reservation.id).attributes

    travel 1.hour
    statements = capture_sql { assert_same reservation, reservation.release!(reason: "operator", metadata: {actor_id: 1}) }

    assert_equal captured, Wallets::Hold.find(reservation.id).attributes
    assert_equal "captured", reservation.release_reason
    assert_equal debit.id, reservation.capture_transaction_id
    assert statements.none? { |sql| sql.match?(/\A\s*(INSERT|UPDATE|DELETE)/i) }, "a no-op writes nothing:\n#{statements.join("\n")}"
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Funding at capture time
  # ───────────────────────────────────────────────────────────────────────────

  test "the reservation funds its own capture, while every other reservation stays in force" do
    wallet = points_wallet(100)
    first = wallet.reserve(60, category: :booking)
    wallet.reserve(40, category: :booking)
    assert_equal 0, wallet.balance

    first.capture!(category: :booking_charge)

    assert_equal [0, 40, 40], balances(wallet)
    assert_raises(Wallets::InsufficientBalance) { wallet.debit(1, category: :purchase) }
  end

  test "a hold placed after the reservation blocks its capture, which stays possible once the hold goes" do
    wallet = points_wallet(100)
    reservation = wallet.reserve(80, category: :booking)
    fraud = wallet.hold(wallet.transactions.credits.sole, category: :fraud_review)
    assert_equal [-80, 180, 100], balances(wallet)

    error = assert_nothing_written(wallet) do
      assert_raises(Wallets::InsufficientBalance) { reservation.capture!(category: :booking_charge) }
    end

    assert_equal "Insufficient balance (0 < 80 to capture reservation #{reservation.id}; 100 held, 80 reserved)", error.message
    assert reservation.reload.active?, "a failed capture leaves the reservation capturable"
    refute reservation.captured?
    assert_equal [-80, 180, 100], balances(wallet)

    fraud.release!
    debit = reservation.capture!(category: :booking_charge)
    assert_equal [20, 20], [debit.balance_before, debit.balance_after], "the reserved 80 was never available"
    assert_equal [20, 0, 20], balances(wallet)
  end

  test "capture never spends value a hold covers" do
    wallet = points_wallet
    held = wallet.credit(100, category: :reward, hold: :fraud_review)
    free = wallet.credit(50, category: :top_up)
    reservation = wallet.reserve(50, category: :booking)

    debit = reservation.capture!(category: :booking_charge)

    assert_equal [[free.id, 50]], allocations(debit)
    assert_equal 100, held.reload.remaining_amount
    assert_equal [0, 100, 100], balances(wallet)
  end

  test "a reservation whose backing expired cannot be captured unless overdrafts are on" do
    freeze_time
    wallet = points_wallet
    wallet.credit(100, category: :reward, expires_at: 1.day.from_now)
    reservation = wallet.reserve(100, category: :booking, until: 3.days.from_now)
    travel 2.days
    assert_equal [-100, 100, 0], balances(wallet)

    assert_raises(Wallets::InsufficientBalance) { reservation.capture!(category: :booking_charge) }
    assert reservation.reload.active?

    Wallets.configuration.allow_negative_balance = true
    debit = reservation.capture!(category: :booking_charge)
    assert_equal 100, debit.unbacked_amount
    assert_equal [-100, 0, -100], balances(wallet)
  end

  test "with overdrafts on, a capture funded by credit buckets leaves no debt, however underfunded the other reservations" do
    # The plan's example: 100 in credits and two reservations of 80.
    Wallets.configuration.allow_negative_balance = true
    wallet = points_wallet(100)
    credit = wallet.transactions.credits.sole
    first = wallet.reserve(80, category: :booking)
    second = wallet.reserve(80, category: :booking)
    assert_equal [-60, 160, 100], balances(wallet)

    debit = first.capture!(category: :booking_charge)

    assert_equal [[credit.id, 80]], allocations(debit)
    assert_equal 0, debit.unbacked_amount, "insufficient availability is not insufficient buckets"
    assert_equal [-60, 80, 20], balances(wallet)
    assert_equal [-60, -60], [debit.balance_before, debit.balance_after]
    assert second.reload.active?
  end

  test "with overdrafts on, a capture beyond the eligible credits leaves exactly the rest unbacked" do
    Wallets.configuration.allow_negative_balance = true
    wallet = points_wallet
    held = wallet.credit(100, category: :reward, hold: :fraud_review)
    free = wallet.credit(30, category: :top_up)
    reservation = wallet.reserve(80, category: :booking)
    assert_equal [-50, 180, 130], balances(wallet)

    debit = reservation.capture!(category: :booking_charge)

    assert_equal [[free.id, 30]], allocations(debit)
    assert_equal 50, debit.unbacked_amount
    assert_equal 100, held.reload.remaining_amount, "held value is never captured"
    assert_equal [-50, 100, 50], balances(wallet)
  end

  test "a capture never lowers the available balance" do
    # The debit takes at most what the reservation already kept out of it.
    Wallets.configuration.allow_negative_balance = true
    wallet = points_wallet(50)
    wallet.hold(wallet.credit(40, category: :reward), category: :fraud_review)

    [[30, 30], [30, 10], [100, 100], [100, 1]].each do |reserved, captured|
      reservation = wallet.reserve(reserved, category: :booking)
      before = wallet.balance

      debit = reservation.capture!(captured, category: :booking_charge)

      assert_operator debit.balance_after, :>=, debit.balance_before
      assert_equal before, debit.balance_before
      assert_equal before + reserved - captured, wallet.balance
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # One lock, one savepoint, one wallet write
  # ───────────────────────────────────────────────────────────────────────────

  test "a capture that fails after its writes leaves the reservation active, even when the caller rescues and commits" do
    wallet = points_wallet(100)
    reservation = wallet.reserve(30, category: :booking)
    reservation.wallet.stubs(:refresh_cached_balance!).raises(ActiveRecord::StatementInvalid, "boom")

    Wallets::Wallet.transaction do
      assert_raises(ActiveRecord::StatementInvalid) { reservation.capture!(category: :booking_charge) }
      Wallets::Wallet.find(wallet.id).credit(5, category: :top_up) # the caller's transaction is still usable
    end

    stored = Wallets::Hold.find(reservation.id)
    assert stored.active?
    refute stored.captured?
    assert_nil stored.release_reason
    assert_empty wallet.transactions.debits
    refute reservation.captured?, "the caller's copy is rolled back with it"
    assert_nil reservation.released_at
  end

  test "a refused capture leaves the caller's copy as the ledger has it" do
    wallet = points_wallet(100)
    reservation = wallet.reserve(30, category: :booking)
    wallet.hold(category: :chargeback)

    assert_raises(Wallets::InsufficientBalance) { reservation.capture!(category: :booking_charge) }

    refute reservation.captured?
    assert reservation.active?
    refute reservation.has_changes_to_save?
  end

  test "capturing a reservation that no longer exists raises the lookup's own error" do
    wallet = points_wallet(100)
    reservation = wallet.reserve(30, category: :booking)
    Wallets::Hold.where(id: reservation.id).delete_all

    assert_raises(ActiveRecord::RecordNotFound) { reservation.capture!(category: :booking_charge) }
    assert_empty wallet.transactions.debits
  end

  test "a failed capture can be retried" do
    wallet = points_wallet(100)
    reservation = wallet.reserve(30, category: :booking)
    reservation.wallet.stubs(:refresh_cached_balance!).raises(ActiveRecord::StatementInvalid, "boom")
    assert_raises(ActiveRecord::StatementInvalid) { reservation.capture!(category: :booking_charge) }
    reservation.wallet.unstub(:refresh_cached_balance!)

    debit = reservation.capture!(category: :booking_charge)

    assert_equal [debit.id], wallet.transactions.debits.pluck(:id)
    assert reservation.reload.captured?
    assert_equal [70, 0, 70], balances(wallet)
    assert_equal 70, wallet.reload.read_attribute(:balance)
  end

  test "capture locks the wallet before it reads the reservation" do
    wallet = points_wallet(100)
    reservation = Wallets::Hold.find(wallet.reserve(30, category: :booking).id)
    reservation.wallet # loaded up front, so only the capture's own reads are captured

    statements = capture_sql { reservation.capture!(category: :booking_charge) }

    wallet_lock = statements.index { |sql| sql.match?(/\ASELECT .* FROM .?wallets_wallets.? .*#{"FOR UPDATE" unless sqlite?}/i) }
    hold_read = statements.index { |sql| sql.match?(/\ASELECT .* FROM .?wallets_holds.? /i) }
    assert wallet_lock, "the wallet is locked:\n#{statements.join("\n")}"
    assert_operator wallet_lock, :<, hold_read, "wallet first, then the reservation"
    assert_match(/FOR UPDATE/, statements[hold_read], "the reservation is read as it is now") unless sqlite?
  end

  test "a whole capture writes the wallet row, though the available balance does not move" do
    wallet = points_wallet(100)
    reservation = wallet.reserve(100, category: :booking)
    before = wallet.reload.updated_at

    travel(1.second) { reservation.capture!(category: :booking_charge) }

    assert_equal 0, wallet.reload.read_attribute(:balance)
    assert_operator wallet.updated_at, :>, before
  end

  test "the pinned instant is released after a capture, even a failing one" do
    wallet = points_wallet(10)
    reservation = wallet.reserve(10, category: :booking)
    wallet.hold(category: :chargeback)

    assert_raises(Wallets::InsufficientBalance) { reservation.capture!(category: :booking_charge) }

    capturing_wallet = reservation.wallet
    assert_nil capturing_wallet.instance_variable_get(:@evaluation_time)
    travel 1.day do
      assert_equal Time.current, capturing_wallet.send(:evaluation_time)
    end
  end

  private

  def points_wallet(initial_balance = 0)
    create_wallet(@owner, asset_code: :points, initial_balance: initial_balance)
  end

  # [available, held, total]
  def balances(wallet)
    [wallet.balance, wallet.held_balance, wallet.total_balance]
  end

  def allocations(spend)
    spend.outgoing_allocations.order(:id).pluck(:source_transaction_id, :amount)
  end

  def sqlite?
    Wallets::Wallet.connection.adapter_name.match?(/sqlite/i)
  end

  def assert_nothing_written(wallet, &block)
    assert_no_changes(-> { [wallet.transactions.count, Wallets::Allocation.count, Wallets::Hold.where(wallet_id: wallet.id).order(:id).pluck(:released_at, :capture_transaction_id)] }, &block)
  end
end
