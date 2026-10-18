# frozen_string_literal: true

require "test_helper"

# Every code sample the README's use-case stories add for holds, run as the
# README writes it, with the values its comments promise: the real-world
# examples that keep value pending, vesting, retained rewards and the
# bank-statement day. A README that lies is a bug: when one of these fails,
# fix the README or the code, never the test alone. (The reference section,
# "Holds and reservations", is pinned by ReadmeHoldsTest.)
#
# The README's owners are fixture users here: `user`, `player`, `sara`,
# `driver`, `seller` and `account` are one person, and `marketplace`,
# `rider` and `platform` another. Lookups the README leaves to the app
# (`order`, `booking`, `ride`) are plain structs.
class ReadmeUseCasesTest < ActiveSupport::TestCase
  setup do
    @user = users(:new_user)
    @other = users(:peer_user)
    # The README's own advice: debit and credit categories are transaction
    # categories. Hold and transfer categories need no configuration.
    Wallets.configuration.additional_categories = Wallets.configuration.additional_categories + %w[
      tournament_prize prize_revoked booking_charge tip weekly_payout sale
      deposit card_payment referral creator_reward signup_bonus reversal
    ]
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Game economy
  # ───────────────────────────────────────────────────────────────────────────

  test "game economy: a tournament prize is retained until anti-cheat clears the match" do
    player = @user

    prize = player.wallet(:gems).credit(
      1_000,
      category: :tournament_prize,
      hold: {category: :anti_cheat_review, metadata: {match_id: 314}}
    )

    assert_equal [0, 1_000, 1_000], balances(player.wallet(:gems))

    prize.holds.find_by(category: :anti_cheat_review).release!(reason: "match_clean")
    assert_equal [1_000, 0, 1_000], balances(player.wallet(:gems))
  end

  test "game economy: a prize is taken back when cheating is confirmed" do
    player = @user
    prize = player.wallet(:gems).credit(1_000, category: :tournament_prize, hold: {category: :anti_cheat_review, metadata: {match_id: 314}})

    player.wallet(:gems).debit(1_000, category: :prize_revoked, from: prize)

    assert_equal [0, 0, 0], balances(player.wallet(:gems))
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Home services booking app
  # ───────────────────────────────────────────────────────────────────────────

  test "home services: the price is reserved at booking and captured at delivery" do
    sara = @user
    marketplace = @other
    booking = Struct.new(:id).new(42)
    sara.wallet(:usd_cents).credit(8_000, category: :top_up)

    # Sara has $80.00 in her wallet and books a 2-hour cleaning for $50.00
    reservation = sara.wallet(:usd_cents).reserve(
      5000,
      category: :booking,
      until: 3.days.from_now,
      metadata: {booking_id: booking.id}
    )

    assert_equal 3_000, sara.wallet(:usd_cents).balance
    assert_equal 5_000, sara.wallet(:usd_cents).held_balance

    # The cleaning took 1.5 hours: charge $37.50 and credit the marketplace
    charge = nil
    ActiveRecord::Base.transaction do
      charge = reservation.capture!(3750, category: :booking_charge, metadata: {booking_id: booking.id})
      marketplace.wallet(:usd_cents).credit(3750, category: :booking_charge, metadata: {booking_id: booking.id, charge_id: charge.id})
    end

    assert_equal 4_250, sara.wallet(:usd_cents).balance
    assert_equal 0, sara.wallet(:usd_cents).held_balance
    assert_equal 3_750, marketplace.wallet(:usd_cents).balance
    assert_equal charge.id, marketplace.wallet(:usd_cents).transactions.sole.metadata[:charge_id]
  end

  test "home services: a cancelled booking gives the reservation back, and an unclaimed one falls off" do
    freeze_time
    sara = @user
    sara.wallet(:usd_cents).credit(8_000, category: :top_up)

    cancelled = sara.wallet(:usd_cents).reserve(5000, category: :booking, until: 3.days.from_now)
    cancelled.release!
    assert_equal 8_000, sara.wallet(:usd_cents).balance, "release! gives Sara her $50.00 back"

    sara.wallet(:usd_cents).reserve(5000, category: :booking, until: 3.days.from_now)
    assert_equal 3_000, sara.wallet(:usd_cents).balance
    travel_to(3.days.from_now) { assert_equal 8_000, sara.wallet(:usd_cents).balance, "nobody captured it: it fell off" }
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Loyalty programs & Reward points
  # ───────────────────────────────────────────────────────────────────────────

  test "loyalty: points stay pending until the return window closes" do
    freeze_time
    user = @user
    order = Struct.new(:id, :total_cents).new(77, 4_250)

    earned = user.wallet(:points).credit(
      order.total_cents / 100,
      category: :purchase,
      available_at: 30.days.from_now,
      metadata: {order_id: order.id}
    )

    assert earned.held?
    assert_equal [0, 42, 42], balances(user.wallet(:points))

    travel_to(30.days.from_now) { assert_equal [42, 0, 42], balances(user.wallet(:points)) }
  end

  test "loyalty: a returned order takes its pending points with it" do
    user = @user
    order = Struct.new(:id, :total_cents).new(77, 4_250)
    earned = user.wallet(:points).credit(order.total_cents / 100, category: :purchase, available_at: 30.days.from_now, metadata: {order_id: order.id})

    other = user.wallet(:points).credit(10, category: :purchase)

    user.wallet(:points).debit(earned.amount, category: :refund, from: earned, metadata: {order_id: order.id})

    assert_equal 0, earned.reload.remaining_amount
    assert_equal 10, other.reload.remaining_amount, "nothing else in the wallet was touched"
    assert_equal [10, 0, 10], balances(user.wallet(:points))
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Gig economy / Driver earnings
  # ───────────────────────────────────────────────────────────────────────────

  test "gig economy: the weekly payout pays cleared earnings, and pending fares wait" do
    freeze_time
    driver = @user
    rider = @other
    ride = Struct.new(:id).new(9)

    driver.wallet(:usd_cents).credit(
      1250,
      category: :ride_fare,
      available_at: 3.days.from_now,
      metadata: {ride_id: ride.id, distance_miles: 5.2}
    )

    tip = driver.wallet(:usd_cents).credit(
      300,
      category: :tip,
      metadata: {ride_id: ride.id, rider_id: rider.id}
    )

    payout = driver.wallet(:usd_cents).debit(
      driver.wallet(:usd_cents).balance,
      category: :weekly_payout,
      metadata: {payout_date: Date.current, bank_account: "****1234"}
    )

    assert_equal [[tip.id, 300]], allocations(payout), "the payout pays the tip, which has cleared"
    assert_equal 1_250, driver.wallet(:usd_cents).held_balance
    travel_to(3.days.from_now) { assert_equal 1_250, driver.wallet(:usd_cents).balance, "next week's payout" }
  end

  test "gig economy: a disputed tip is retained until support decides" do
    driver = @user
    ride = Struct.new(:id).new(9)
    driver.wallet(:usd_cents).credit(1250, category: :ride_fare, available_at: 3.days.from_now, metadata: {ride_id: ride.id})
    tip = driver.wallet(:usd_cents).credit(300, category: :tip, metadata: {ride_id: ride.id})

    dispute = driver.wallet(:usd_cents).hold(tip, category: :dispute, metadata: {ride_id: ride.id})
    assert_equal 0, driver.wallet(:usd_cents).balance, "the payout skips the retained tip"

    dispute.release!(reason: "resolved_for_driver")
    assert_equal 300, driver.wallet(:usd_cents).balance
  end

  test "gig economy: a dispute the rider wins gives the retained tip back" do
    driver = @user
    rider = @other
    ride = Struct.new(:id).new(9)
    tip = driver.wallet(:usd_cents).credit(300, category: :tip, metadata: {ride_id: ride.id})
    driver.wallet(:usd_cents).hold(tip, category: :dispute, metadata: {ride_id: ride.id})

    driver.wallet(:usd_cents).transfer_to(rider.wallet(:usd_cents), 300, category: :tip_refund, from: tip)

    assert_equal 0, driver.wallet(:usd_cents).total_balance
    assert_equal 300, rider.wallet(:usd_cents).balance
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Marketplace seller earnings
  # ───────────────────────────────────────────────────────────────────────────

  test "marketplace: a seller's earnings are held through the return window" do
    freeze_time
    seller = @user
    order = Struct.new(:id).new(77)

    earnings = seller.wallet(:eur_cents).credit(
      4_500,
      category: :sale,
      hold: {category: :return_window, until: 14.days.from_now},
      metadata: {order_id: order.id}
    )

    assert_equal ["return_window"], earnings.holds.active.map(&:category)
    assert_equal 0, seller.wallet(:eur_cents).balance
    assert_equal 4_500, seller.wallet(:eur_cents).held_balance

    travel_to(14.days.from_now) { assert_equal 4_500, seller.wallet(:eur_cents).balance }
  end

  test "marketplace: a return inside the window cancels the held earnings and nothing else" do
    seller = @user
    order = Struct.new(:id).new(77)
    seller.wallet(:eur_cents).credit(2_000, category: :sale, metadata: {order_id: 76})
    earnings = seller.wallet(:eur_cents).credit(4_500, category: :sale, hold: {category: :return_window, until: 14.days.from_now}, metadata: {order_id: order.id})

    debit = seller.wallet(:eur_cents).debit(4_500, category: :refund, from: earnings, metadata: {order_id: order.id, reason: "returned"})

    assert_equal [[earnings.id, 4_500]], allocations(debit), "only that sale's earnings"
    assert_equal [2_000, 0, 2_000], balances(seller.wallet(:eur_cents)), "the seller's other money is untouched"
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Bank-style accounts and fintech
  # ───────────────────────────────────────────────────────────────────────────

  test "fintech: one day of a bank-style account, read as available and current" do
    monday = Time.zone.local(2026, 10, 19)
    travel_to monday.change(hour: 8)
    account = @user
    wallet = create_wallet(account, asset_code: :eur_cents, initial_balance: 50_000)

    # 08:00 Salary arrives. It clears tomorrow.
    wallet.credit(200_000, category: :deposit, available_at: 1.day.from_now)
    assert_equal [50_000, 250_000], statement(wallet)

    # 09:00 The fuel pump pre-authorises €100.00 on the card.
    travel_to monday.change(hour: 9)
    fuel = wallet.reserve(10_000, category: :card_authorization, until: 7.days.from_now, metadata: {merchant: "Fuel station"})
    assert_equal [40_000, 250_000], statement(wallet)

    # 09:05 The pump charges what was really filled, €62.40.
    travel_to monday.change(hour: 9, min: 5)
    fuel.capture!(6_240, category: :card_payment)
    assert_equal [43_760, 243_760], statement(wallet)

    # 15:00 Hotel check-in: a €150.00 hold for extras, never captured.
    travel_to monday.change(hour: 15)
    wallet.reserve(15_000, category: :card_authorization, until: 3.days.from_now, metadata: {merchant: "Hotel"})
    assert_equal [28_760, 243_760], statement(wallet)

    # Tuesday 08:00: the salary has cleared.
    travel_to monday.tomorrow.change(hour: 8)
    assert_equal [228_760, 243_760], statement(wallet)

    # Thursday 15:00: the hotel's hold has fallen off.
    travel_to monday.advance(days: 3).change(hour: 15)
    assert_equal [243_760, 243_760], statement(wallet)
    assert_equal 0, wallet.held_balance, "nothing pending: the two balances agree"
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Vesting rewards
  # ───────────────────────────────────────────────────────────────────────────

  test "vesting: a referral bonus unlocks after 14 days" do
    freeze_time
    points = @user.wallet(:points)

    points.credit(500, category: :referral, available_at: 14.days.from_now)

    assert_equal 0, points.balance
    assert_equal 500, points.held_balance
    assert_equal 500, points.total_balance

    travel_to(14.days.from_now) { assert_equal 500, points.balance }
  end

  test "vesting: a creator reward vests on a monthly schedule" do
    freeze_time
    points = @user.wallet(:points)

    [1, 2, 3].each do |month|
      points.credit(400, category: :creator_reward, available_at: month.months.from_now)
    end

    assert_equal 0, points.balance
    assert_equal 1_200, points.held_balance

    travel_to(2.months.from_now) do
      assert_equal 800, points.balance
      assert_equal 400, points.held_balance
    end
  end

  test "vesting: a signup bonus vests when the app says the condition is met" do
    points = @user.wallet(:points)

    bonus = points.credit(1_000, category: :signup_bonus, hold: :first_order_pending)

    assert_equal 0, points.balance
    assert_equal 1_000, points.total_balance

    bonus.holds.find_by(category: :first_order_pending).release!(reason: "first_order_completed")
    assert_equal 1_000, points.balance
  end

  test "vesting: a bonus whose condition is never met is taken back with from:" do
    points = @user.wallet(:points)
    bonus = points.credit(1_000, category: :signup_bonus, hold: :first_order_pending)

    points.debit(1_000, category: :reversal, from: bonus)

    assert_equal [0, 0, 0], balances(points)
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Retained rewards and reviews
  # ───────────────────────────────────────────────────────────────────────────

  test "retained: a reward is credited now and retained until the programme reimburses it" do
    wallet = @user.wallet(:eur_cents)

    reward = wallet.credit(
      1_500,
      category: :reward,
      hold: {category: :awaiting_reimbursement, metadata: {programme: "partner_cashback", claim_id: 88}}
    )

    assert_equal 0, wallet.balance
    assert_equal 1_500, wallet.total_balance

    reward.holds.find_by(category: :awaiting_reimbursement).release!(reason: "reimbursed")
    assert_equal 1_500, wallet.balance
  end

  test "retained: a rejected claim takes the retained reward back" do
    wallet = @user.wallet(:eur_cents)
    reward = wallet.credit(1_500, category: :reward, hold: {category: :awaiting_reimbursement, metadata: {programme: "partner_cashback", claim_id: 88}})

    wallet.debit(1_500, category: :reversal, from: reward, metadata: {reason: "claim_rejected"})

    assert_equal 0, wallet.total_balance
  end

  test "retained: a review retains one credit, several, or the whole account" do
    wallet = @user.wallet(:eur_cents)
    reward = wallet.credit(1_500, category: :reward)
    suspicious_rewards = [wallet.credit(500, category: :reward), wallet.credit(700, category: :reward)]
    untouched = wallet.credit(100, category: :reward)

    wallet.hold(reward, category: :fraud_review, metadata: {case_id: 42})
    assert_equal [1_300, 1_500, 2_800], balances(wallet), "one credit"

    review = suspicious_rewards.map do |credit|
      wallet.hold(credit, category: :fraud_review, metadata: {case_id: 42})
    end
    assert_equal 2, review.size
    assert_equal [100, 2_700, 2_800], balances(wallet), "several credits"
    refute untouched.held?

    wallet.hold(category: :compliance_review, metadata: {case_id: 43})
    assert wallet.on_hold?
    assert_equal [0, 2_800, 2_800], balances(wallet), "the whole account"
    assert wallet.credit(50, category: :reward).held?, "credits that arrive during the review included"
  end

  test "retained: the app reads a credit's reasons, and the account's, to explain them" do
    wallet = @user.wallet(:eur_cents)
    reward = wallet.credit(1_500, category: :reward, hold: :awaiting_reimbursement)
    wallet.hold(reward, category: :fraud_review, metadata: {case_id: 42})
    wallet.hold(category: :compliance_review, metadata: {case_id: 43})

    assert reward.held?
    assert_equal ["awaiting_reimbursement", "fraud_review"], reward.holds.active.order(:id).map(&:category)
    assert wallet.on_hold?
  end

  test "retained: a cleared review releases exactly the holds it placed" do
    wallet = @user.wallet(:eur_cents)
    suspicious_rewards = [wallet.credit(500, category: :reward), wallet.credit(700, category: :reward)]
    other_case = wallet.hold(suspicious_rewards.first, category: :dispute)
    review = suspicious_rewards.map { |credit| wallet.hold(credit, category: :fraud_review, metadata: {case_id: 42}) }
    account_review = wallet.hold(category: :compliance_review, metadata: {case_id: 43})
    assert_equal [0, 1_200, 1_200], balances(wallet)

    wallet.with_lock { review.each { |hold| hold.release!(reason: "cleared") } }
    account_review.release!(reason: "cleared")

    assert (review + [account_review]).all? { |hold| hold.reload.release_reason == "cleared" }
    refute wallet.on_hold?
    assert other_case.reload.active?, "another case's hold stays"
    assert_equal [700, 500, 1_200], balances(wallet)
  end

  test "retained: a confirmed review takes the retained value, here into the platform's wallet" do
    platform = @other
    wallet = @user.wallet(:eur_cents)
    suspicious_rewards = [wallet.credit(500, category: :reward), wallet.credit(700, category: :reward)]
    review = suspicious_rewards.map { |credit| wallet.hold(credit, category: :fraud_review, metadata: {case_id: 42}) }
    account_review = wallet.hold(category: :compliance_review, metadata: {case_id: 43})

    wallet.transfer_to(platform.wallet(:eur_cents), suspicious_rewards.sum(&:remaining_amount), category: :reversal, from: suspicious_rewards)
    account_review.release!(reason: "confirmed")

    assert_equal [0, 0, 0], balances(wallet)
    assert_equal 1_200, platform.wallet(:eur_cents).balance
    assert review.all? { |hold| hold.reload.active? }, "from: leaves the credits' hold rows where they are"
    refute wallet.on_hold?, "the account hold was ended by hand"
    assert_equal 300, wallet.credit(300, category: :reward).available_amount, "so later credits arrive spendable"
  end

  private

  # [available, held, total]
  def balances(wallet)
    [wallet.balance, wallet.held_balance, wallet.total_balance]
  end

  # [available, current], the two balances a bank statement shows.
  def statement(wallet)
    [wallet.balance, wallet.total_balance]
  end

  def allocations(debit)
    debit.outgoing_allocations.order(:id).pluck(:source_transaction_id, :amount)
  end
end
