# frozen_string_literal: true

require "test_helper"

# A command given an `idempotency_key:` posts once. A retry with the same key
# returns the row the first call wrote, posts nothing and reports nothing;
# the same key for a different command raises Wallets::IdempotencyConflict.
# Races between real connections live in CurrentReadsTest.
class Wallets::IdempotencyKeyTest < ActiveSupport::TestCase
  setup do
    Wallets.configuration.additional_categories = Wallets.configuration.additional_categories + %w[run]
    @owner = users(:new_user)
    @wallet = create_wallet(@owner, asset_code: :points, initial_balance: 1_000)
    @other = create_wallet(users(:peer_user), asset_code: :points)
  end

  # ───────────────────────────────────────────────────────────────────────────
  # A retry returns the first row and posts nothing
  # ───────────────────────────────────────────────────────────────────────────

  test "a retried credit returns the first credit and adds the value once" do
    first = @wallet.credit(500, category: :top_up, idempotency_key: "invoice:1")
    retry_ = @wallet.credit(500, category: :top_up, idempotency_key: "invoice:1")

    assert_equal first, retry_
    assert_equal "invoice:1", first.reload.idempotency_key
    assert_equal 1_500, @wallet.reload.balance
    assert_equal 1, @wallet.transactions.where(idempotency_key: "invoice:1").count
  end

  test "a retried debit returns the first debit and takes the value once" do
    first = @wallet.debit(300, category: :purchase, idempotency_key: "order:7")
    retry_ = @wallet.debit(300, category: :purchase, idempotency_key: "order:7")

    assert_equal first, retry_
    assert_equal 700, @wallet.reload.balance
  end

  test "a retried debit is returned even when the wallet could no longer fund it" do
    first = @wallet.debit(1_000, category: :purchase, idempotency_key: "order:all")

    assert_equal first, @wallet.debit(1_000, category: :purchase, idempotency_key: "order:all")
    assert_equal 0, @wallet.reload.balance
  end

  test "a retried transfer returns the first transfer and moves the value once" do
    first = @wallet.transfer_to(@other, 250, category: :peer_payment, idempotency_key: "payment:3")
    retry_ = @wallet.transfer_to(@other, 250, category: :peer_payment, idempotency_key: "payment:3")

    assert_equal first, retry_
    assert_equal [750, 250], [@wallet.reload.balance, @other.reload.balance]
    assert_equal 1, Wallets::Transfer.count
    assert_equal "payment:3", @wallet.transactions.find_by!(category: "transfer_out").idempotency_key
    assert_nil @other.transactions.find_by!(category: "transfer_in").idempotency_key, "the key is the sender's"
  end

  test "a retried reservation returns the first reservation and sets the amount aside once" do
    first = @wallet.reserve(400, category: :run, until: 1.hour.from_now, idempotency_key: "run:1")
    # A job that retries recomputes its deadline: still the same reservation.
    retry_ = @wallet.reserve(400, category: :run, until: 2.hours.from_now, idempotency_key: "run:1")

    assert_equal first, retry_
    assert_equal "run:1", first.reload.idempotency_key
    assert_equal [600, 400], [@wallet.reload.balance, @wallet.held_balance]
  end

  test "a retried hold returns the first hold" do
    credit = @wallet.transactions.credits.sole
    first = @wallet.hold(credit, category: :fraud_review, idempotency_key: "case:9")

    assert_equal first, @wallet.hold(credit, category: :fraud_review, idempotency_key: "case:9")
    assert_equal 1, @wallet.holds.count
  end

  test "a retried capture returns the first debit instead of raising for the ended reservation" do
    reservation = @wallet.reserve(400, category: :run, idempotency_key: "run:2")
    first = reservation.capture!(350, category: :run, idempotency_key: "run:2")
    retry_ = reservation.capture!(350, category: :run, idempotency_key: "run:2")

    assert_equal first, retry_
    assert_equal first, reservation.reload.capture_transaction
    assert_equal 650, @wallet.reload.balance
    assert_equal 1, @wallet.transactions.debits.count
  end

  test "a retried capture is recognised through a fresh copy of the reservation" do
    reservation = @wallet.reserve(400, category: :run)
    first = reservation.capture!(category: :run, idempotency_key: "run:3")

    assert_equal first, Wallets::Hold.find(reservation.id).capture!(category: :run, idempotency_key: "run:3")
    assert_equal first, Wallets::Hold.find(reservation.id).capture!(400, category: :run, idempotency_key: "run:3")
  end

  test "a capture without a key still raises when retried" do
    reservation = @wallet.reserve(400, category: :run)
    reservation.capture!(category: :run)

    assert_raises(Wallets::InvalidHold) { reservation.capture!(category: :run) }
    assert_raises(Wallets::InvalidHold) { reservation.capture!(category: :run, idempotency_key: "late") }
  end

  test "a retried reservation returns the reservation as it is now, captured or not" do
    reservation = @wallet.reserve(400, category: :run, idempotency_key: "run:4")
    reservation.capture!(category: :run)

    assert @wallet.reserve(400, category: :run, idempotency_key: "run:4").captured?
  end

  test "a reservation and its capture may share one key: holds and transactions keep their own" do
    reservation = @wallet.reserve(400, category: :run, idempotency_key: "effect:1")
    debit = reservation.capture!(300, category: :run, idempotency_key: "effect:1")

    assert_equal [reservation, debit], [
      @wallet.reserve(400, category: :run, idempotency_key: "effect:1"),
      reservation.capture!(300, category: :run, idempotency_key: "effect:1")
    ]
    assert_equal 700, @wallet.reload.balance
  end

  test "a retry reports nothing" do
    events = []
    Wallets.configure do |config|
      config.on_balance_credited { |ctx| events << ctx.event }
      config.on_balance_debited { |ctx| events << ctx.event }
      config.on_hold_created { |ctx| events << ctx.event }
      config.on_transfer_completed { |ctx| events << ctx.event }
    end

    @wallet.credit(1, category: :top_up, idempotency_key: "c")
    @wallet.debit(1, category: :purchase, idempotency_key: "d")
    @wallet.reserve(1, category: :run, idempotency_key: "r")
    @wallet.transfer_to(@other, 1, idempotency_key: "t")
    first_calls = events.dup
    events.clear

    @wallet.credit(1, category: :top_up, idempotency_key: "c")
    @wallet.debit(1, category: :purchase, idempotency_key: "d")
    @wallet.reserve(1, category: :run, idempotency_key: "r")
    @wallet.transfer_to(@other, 1, idempotency_key: "t")

    refute_empty first_calls
    assert_empty events
  end

  # ───────────────────────────────────────────────────────────────────────────
  # A key names one command
  # ───────────────────────────────────────────────────────────────────────────

  test "the same key with another amount or category is a conflict, and posts nothing" do
    @wallet.credit(500, category: :top_up, idempotency_key: "invoice:2")

    assert_raises(Wallets::IdempotencyConflict) { @wallet.credit(501, category: :top_up, idempotency_key: "invoice:2") }
    assert_raises(Wallets::IdempotencyConflict) { @wallet.credit(500, category: :reward, idempotency_key: "invoice:2") }
    assert_equal 1_500, @wallet.reload.balance
  end

  test "a key used by one command is a conflict for any other" do
    @wallet.credit(100, category: :credit, idempotency_key: "k")
    reservation = @wallet.reserve(100, category: :run)

    error = assert_raises(Wallets::IdempotencyConflict) { @wallet.debit(100, category: :credit, idempotency_key: "k") }
    assert_match(/"k" was already used on wallet #{@wallet.id} for a different command \(transaction \d+\)/, error.message)
    assert_raises(Wallets::IdempotencyConflict) { @wallet.transfer_to(@other, 100, idempotency_key: "k") }
    assert_raises(Wallets::IdempotencyConflict) { reservation.capture!(100, category: :credit, idempotency_key: "k") }
    assert reservation.reload.active?, "the reservation is left as it was"
  end

  test "a plain debit's key never replays a capture, nor a capture's key a plain debit" do
    reservation = @wallet.reserve(100, category: :run)
    reservation.capture!(category: :run, idempotency_key: "captured")
    @wallet.debit(50, category: :run, idempotency_key: "debited")
    other_reservation = @wallet.reserve(50, category: :run)

    assert_raises(Wallets::IdempotencyConflict) { @wallet.debit(100, category: :run, idempotency_key: "captured") }
    assert_raises(Wallets::IdempotencyConflict) { other_reservation.capture!(50, category: :run, idempotency_key: "debited") }
  end

  test "a capture's key is a conflict on another reservation or for another amount" do
    first = @wallet.reserve(100, category: :run)
    second = @wallet.reserve(100, category: :run)
    first.capture!(80, category: :run, idempotency_key: "run:5")

    assert_raises(Wallets::IdempotencyConflict) { second.capture!(80, category: :run, idempotency_key: "run:5") }
    assert_raises(Wallets::IdempotencyConflict) { first.capture!(90, category: :run, idempotency_key: "run:5") }
    assert_raises(Wallets::IdempotencyConflict) { first.capture!(80, category: :booking, idempotency_key: "run:5") }
    assert second.reload.active?
  end

  test "a transfer's key is a conflict for another recipient or amount" do
    third = create_wallet(users(:poor_user), asset_code: :points)
    @wallet.transfer_to(@other, 100, idempotency_key: "payment:4")

    assert_raises(Wallets::IdempotencyConflict) { @wallet.transfer_to(third, 100, idempotency_key: "payment:4") }
    assert_raises(Wallets::IdempotencyConflict) { @wallet.transfer_to(@other, 101, idempotency_key: "payment:4") }
    assert_raises(Wallets::IdempotencyConflict) { @wallet.transfer_to(@other, 100, category: :peer_payment, idempotency_key: "payment:4") }
    assert_equal 0, third.reload.balance
  end

  test "a hold's key is a conflict on another credit, for the whole wallet, or for a reservation" do
    credit = @wallet.transactions.credits.sole
    other_credit = @wallet.credit(10)
    @wallet.hold(credit, category: :review, idempotency_key: "h")

    assert_raises(Wallets::IdempotencyConflict) { @wallet.hold(other_credit, category: :review, idempotency_key: "h") }
    assert_raises(Wallets::IdempotencyConflict) { @wallet.hold(category: :review, idempotency_key: "h") }
    assert_raises(Wallets::IdempotencyConflict) { @wallet.reserve(10, category: :review, idempotency_key: "h") }
  end

  test "keys are per wallet" do
    @wallet.credit(10, idempotency_key: "shared")
    @other.credit(10, idempotency_key: "shared")

    assert_equal [1_010, 10], [@wallet.reload.balance, @other.reload.balance]
  end

  test "a symbol or a number names the same key as its string" do
    first = @wallet.credit(10, idempotency_key: :welcome)

    assert_equal first, @wallet.credit(10, idempotency_key: "welcome")
    assert_equal @wallet.credit(5, idempotency_key: 42), @wallet.credit(5, idempotency_key: "42")
  end

  test "a blank key is refused before anything is written" do
    ["", "  "].each do |blank|
      error = assert_raises(ArgumentError) { @wallet.credit(10, idempotency_key: blank) }
      assert_equal "idempotency_key can't be blank", error.message
    end
    assert_equal 1_000, @wallet.reload.balance
  end

  test "commands without a key never look one up" do
    statements = capture_sql { @wallet.credit(10) && @wallet.debit(10) && @wallet.reserve(10, category: :run) }

    assert_empty statements.grep(/WHERE.*idempotency_key/)
  end

  # ───────────────────────────────────────────────────────────────────────────
  # The key is stored only when the command commits
  # ───────────────────────────────────────────────────────────────────────────

  test "a refused command stores no key, so its retry runs for real" do
    assert_raises(Wallets::InsufficientBalance) { @wallet.debit(5_000, category: :purchase, idempotency_key: "big") }
    @wallet.credit(4_000)

    debit = @wallet.debit(5_000, category: :purchase, idempotency_key: "big")
    assert_equal "big", debit.idempotency_key
    assert_equal 0, @wallet.reload.balance
  end

  test "a command rolled back with its caller's transaction stores no key" do
    ActiveRecord::Base.transaction(requires_new: true) do
      @wallet.credit(10, idempotency_key: "rolled-back")
      raise ActiveRecord::Rollback
    end

    assert_equal 10, @wallet.credit(10, idempotency_key: "rolled-back").amount
    assert_equal 1_010, @wallet.reload.balance
  end

  test "the database keeps one key per wallet even past the commands" do
    @wallet.credit(10, idempotency_key: "unique")

    assert_raises(ActiveRecord::RecordNotUnique) do
      Wallets::Transaction.create!(wallet: @wallet, amount: 10, category: :credit, idempotency_key: "unique")
    end
    @wallet.reserve(10, category: :run, idempotency_key: "unique")
    assert_raises(ActiveRecord::RecordNotUnique) { reservation!(@wallet, 10, idempotency_key: "unique") }
  end

  # ───────────────────────────────────────────────────────────────────────────
  # A ledger without the column refuses keys, never drops them
  # ───────────────────────────────────────────────────────────────────────────

  test "a ledger whose tables predate idempotency keys refuses a key and works without one" do
    transaction_columns = Wallets::Transaction.column_names - ["idempotency_key"]
    hold_columns = Wallets::Hold.column_names - ["idempotency_key"]
    Wallets::Transaction.stubs(:column_names).returns(transaction_columns)
    Wallets::Hold.stubs(:column_names).returns(hold_columns)

    error = assert_raises(Wallets::Error) { @wallet.credit(10, idempotency_key: "k") }
    assert_equal "wallets_transactions has no idempotency_key column: run `rails g wallets:upgrade` and migrate to use idempotency keys", error.message
    assert_raises(Wallets::Error) { @wallet.reserve(10, category: :run, idempotency_key: "k") }
    assert_equal 1_000, @wallet.reload.balance

    assert_equal 10, @wallet.credit(10).amount
  end
end
