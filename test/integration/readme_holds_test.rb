# frozen_string_literal: true

require "test_helper"

# Every code sample in the README's "Holds and reservations" section, run as
# the README writes it, with the values its comments promise. A README that
# lies is a bug: when one of these fails, fix the README or the code, never
# the test alone. (The embedding recipe is pinned by EmbeddabilityTest, and
# the upgrade commands by UpgradeGeneratorTest.)
class ReadmeHoldsTest < ActiveSupport::TestCase
  setup do
    @owner = users(:new_user)
    # The README's own advice: debit categories are transaction categories.
    Wallets.configuration.additional_categories = Wallets.configuration.additional_categories + %w[reversal booking_charge]
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Pending value you received
  # ───────────────────────────────────────────────────────────────────────────

  test "a credit can arrive held" do
    wallet = new_wallet

    credit = wallet.credit(751, category: :reward, hold: :pending_validation)

    assert_equal 0, wallet.balance
    assert_equal 751, wallet.held_balance
    assert_equal 751, wallet.total_balance

    assert credit.held?
    assert_equal ["pending_validation"], credit.holds.active.map(&:category)
  end

  test "a held credit can carry a deadline and its own metadata" do
    freeze_time
    wallet = new_wallet

    credit = wallet.credit(751, category: :reward, metadata: {ride_id: 7},
      hold: {category: :pending_validation, until: 3.months.from_now, metadata: {case_id: 42}})

    hold = credit.holds.sole
    assert_equal 3.months.from_now, hold.releases_at
    assert_equal({"case_id" => 42}, hold.metadata)
    assert_equal 7, credit.metadata[:ride_id]
    assert_equal 0, wallet.balance
    travel_to(3.months.from_now) { assert_equal 751, wallet.balance }
  end

  test "available_at: unlocks a credit at a given time" do
    freeze_time
    wallet = new_wallet

    credit = wallet.credit(500, category: :reward, available_at: 14.days.from_now)

    assert_equal "pending", credit.holds.sole.category
    assert_equal 0, wallet.balance
    travel_to(14.days.from_now) { assert_equal 500, wallet.balance }
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Holding value that already landed
  # ───────────────────────────────────────────────────────────────────────────

  test "a credit already in the wallet can be held" do
    wallet = new_wallet
    credit = wallet.credit(100, category: :reward)

    hold = wallet.hold(credit, category: :fraud_review, metadata: {case_id: 42})

    assert_equal credit, hold.credit
    assert_equal [0, 100, 100], balances(wallet)
  end

  test "a credit stays held until its last reason is released" do
    wallet = new_wallet
    credit = wallet.credit(100, category: :reward)

    fraud = wallet.hold(credit, category: :fraud_review)
    dispute = wallet.hold(credit, category: :dispute, until: 30.days.from_now)
    assert_equal 100, wallet.held_balance, "two reasons, counted once"

    fraud.release!
    assert credit.held?, "the dispute still holds it"

    dispute.release!
    refute credit.held?
  end

  test "leaving the credit out holds the whole wallet, later credits included" do
    wallet = new_wallet(100)

    wallet.hold(category: :chargeback, metadata: {case_id: 7})

    assert wallet.on_hold?
    assert_equal 0, wallet.balance
    assert wallet.credit(40, category: :reward).held?
  end

  test "release! records why a hold ended next to why it began" do
    wallet = new_wallet
    credit = wallet.credit(100, category: :reward)
    hold = wallet.hold(credit, category: :fraud_review, metadata: {case_id: 42})

    hold.release!(reason: "cleared_by_operator", metadata: {actor_id: 12})

    assert hold.released?
    assert_equal "cleared_by_operator", hold.release_reason
    assert_equal({"actor_id" => 12}, hold.release_metadata)
    assert_equal({"case_id" => 42}, hold.metadata)
    assert_equal 100, wallet.balance
  end

  test "a reviewed set of holds is released inside one wallet lock" do
    wallet = new_wallet(100)
    reviewed_holds = [wallet.hold(category: :chargeback), wallet.hold(wallet.transactions.credits.sole, category: :fraud_review)]
    not_reviewed = wallet.hold(category: :kyc_pending)

    wallet.with_lock do
      reviewed_holds.each { |hold| hold.release!(reason: "cleared_by_operator") }
    end

    assert reviewed_holds.all? { |hold| hold.reload.release_reason == "cleared_by_operator" }
    assert not_reviewed.reload.active?, "only the reviewed holds are released"
  end

  test "holds are found through the wallet and through each credit" do
    wallet = new_wallet
    credit = wallet.credit(100, category: :reward, hold: :pending_validation)
    pending = credit.holds.sole
    wallet.credit(50, category: :top_up)
    reservation = wallet.reserve(30, category: :booking)
    whole_wallet = wallet.hold(category: :chargeback)
    wallet.hold(credit, category: :dispute).release!

    assert_equal [pending, reservation, whole_wallet].map(&:id), wallet.holds.active.order(:id).pluck(:id)
    assert_equal [pending, whole_wallet].map(&:id), wallet.holds.coverage.active.order(:id).pluck(:id)
    assert_equal [reservation], wallet.holds.reservations.active.to_a
    assert_equal [pending], credit.holds.active.to_a
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Reserving value you are about to charge
  # ───────────────────────────────────────────────────────────────────────────

  test "a reservation is captured for what the service really cost" do
    wallet = new_wallet(10_000)
    assert_equal 10_000, wallet.balance

    reservation = wallet.reserve(3_000, category: :booking, until: 7.days.from_now, metadata: {booking_id: 42})

    assert_equal 7_000, wallet.balance
    assert_equal 3_000, wallet.held_balance

    debit = reservation.capture!(2_750, category: :booking_charge, metadata: {booking_id: 42})

    assert_equal 7_250, wallet.balance
    assert reservation.captured?
    assert_equal debit, reservation.capture_transaction
    assert_equal(-2_750, debit.amount)
    assert_equal 0, wallet.held_balance, "the rest of the reservation was released"
  end

  test "reservations add up" do
    wallet = new_wallet(100)

    wallet.reserve(40, category: :booking)
    wallet.reserve(40, category: :booking)

    assert_equal 80, wallet.held_balance
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Ending a hold by taking the value
  # ───────────────────────────────────────────────────────────────────────────

  test "from: takes held value back" do
    wallet = new_wallet
    credit = wallet.credit(751, category: :reward, hold: :pending_validation)

    debit = wallet.debit(751, category: :reversal, from: credit, metadata: {reason: "reward_rejected"})

    assert_equal [[credit.id, 751]], allocations(debit)
    assert_equal [0, 0, 0], balances(wallet)
  end

  test "from: moves held value to another wallet instead" do
    wallet = new_wallet
    platform_wallet = create_wallet(users(:peer_user), asset_code: :eur_cents)
    credit = wallet.credit(751, category: :reward, hold: :pending_validation)

    transfer = wallet.transfer_to(platform_wallet, 751, category: :reversal, from: credit)

    assert_equal [[credit.id, 751]], allocations(transfer.outbound_transaction)
    assert_equal [0, 0, 0], balances(wallet)
    assert_equal 751, platform_wallet.balance
  end

  test "from: spends a list of credits in the order given" do
    wallet = new_wallet
    second_credit = wallet.credit(100, category: :reward) # older, so an ordinary debit would spend it first
    first_credit = wallet.credit(100, category: :reward)

    debit = wallet.debit(150, category: :reversal, from: [first_credit, second_credit])

    assert_equal [[first_credit.id, 100], [second_credit.id, 50]], allocations(debit)
  end

  # ───────────────────────────────────────────────────────────────────────────
  # How holds change the rules you already know
  # ───────────────────────────────────────────────────────────────────────────

  test "available balance can go negative without any overdraft" do
    refute Wallets.configuration.allow_negative_balance
    wallet = new_wallet
    credit = wallet.credit(100, category: :reward)

    wallet.reserve(80, category: :booking)
    wallet.hold(credit, category: :fraud_review)

    assert_equal(-80, wallet.balance)
    assert_equal 180, wallet.held_balance
    assert_equal 100, wallet.total_balance
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Hold callbacks
  # ───────────────────────────────────────────────────────────────────────────

  test "the hold callbacks log what happened" do
    log = StringIO.new
    original_logger = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(log)

    Wallets.configure do |config|
      config.on_hold_created do |ctx|
        Rails.logger.info("[Wallets] #{ctx.category} hold on wallet #{ctx.wallet.id}, available #{ctx.previous_balance} -> #{ctx.new_balance}")
      end

      config.on_hold_released do |ctx|
        if ctx.transaction
          Rails.logger.info("[Wallets] Reservation #{ctx.hold.id} captured as transaction #{ctx.transaction.id}")
        else
          Rails.logger.info("[Wallets] Hold #{ctx.hold.id} released: #{ctx.hold.release_reason}")
        end
      end
    end

    wallet = new_wallet(100)
    hold = wallet.hold(category: :chargeback)
    hold.release!(reason: "resolved")
    reservation = wallet.reserve(30, category: :booking)
    debit = reservation.capture!(category: :booking_charge)

    assert_equal [
      "[Wallets] chargeback hold on wallet #{wallet.id}, available 100 -> 0",
      "[Wallets] Hold #{hold.id} released: resolved",
      "[Wallets] booking hold on wallet #{wallet.id}, available 100 -> 70",
      "[Wallets] Reservation #{reservation.id} captured as transaction #{debit.id}"
    ], log.string.lines(chomp: true).grep(/\A\[Wallets\]/)
  ensure
    Rails.logger = original_logger
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Not in this release
  # ───────────────────────────────────────────────────────────────────────────

  test "credits that arrived by transfer are held in a second step" do
    freeze_time
    buyer_wallet = create_wallet(users(:peer_user), asset_code: :eur_cents, initial_balance: 5_000)
    seller_wallet = new_wallet

    transfer = buyer_wallet.transfer_to(seller_wallet, 5_000, category: :sale)

    transfer.inbound_transactions.each do |credit|
      seller_wallet.hold(credit, category: :return_window, until: 14.days.from_now)
    end

    assert_equal [0, 5_000, 5_000], balances(seller_wallet)
    travel_to(14.days.from_now) { assert_equal 5_000, seller_wallet.balance }
  end

  private

  def new_wallet(initial_balance = 0)
    create_wallet(@owner, asset_code: :eur_cents, initial_balance: initial_balance)
  end

  # [available, held, total]
  def balances(wallet)
    [wallet.balance, wallet.held_balance, wallet.total_balance]
  end

  def allocations(debit)
    debit.outgoing_allocations.order(:id).pluck(:source_transaction_id, :amount)
  end
end
