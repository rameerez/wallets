# frozen_string_literal: true

require "test_helper"

# The hold commands: `hold`, `reserve`, `Hold#release!`, and a credit that
# arrives held (`credit(hold:)` / `credit(available_at:)`). Each one runs
# under the wallet lock, at one instant, and leaves the wallet row written.
# Their callbacks are pinned in WalletCallbacksTest, their races in
# CurrentReadsTest.
class Wallets::WalletHoldCommandsTest < ActiveSupport::TestCase
  # Same table and row as Wallets::Transaction, yet another ledger's class.
  class OtherLedgerTransaction < Wallets::Transaction
  end

  setup do
    @owner = users(:new_user)
  end

  # ───────────────────────────────────────────────────────────────────────────
  # hold: one credit
  # ───────────────────────────────────────────────────────────────────────────

  test "holding a credit moves its value from available to held" do
    wallet = points_wallet
    credit = wallet.credit(100, category: :reward)
    wallet.credit(50, category: :top_up)

    hold = wallet.hold(credit, category: :fraud_review, metadata: {case_id: 42})

    assert_instance_of Wallets::Hold, hold
    assert hold.persisted?
    assert_equal wallet, hold.wallet
    assert_equal credit, hold.credit
    assert_equal "fraud_review", hold.category
    assert_equal 42, hold.reload.metadata[:case_id]
    assert_nil hold.amount
    assert_nil hold.releases_at
    assert hold.credit_scoped?
    assert hold.active?
    assert_equal [hold], credit.holds.to_a

    assert_equal [50, 100, 150], balances(wallet)
    assert credit.held?
    refute wallet.on_hold?, "a credit hold is not a hold on the wallet"
    assert_equal 50, wallet.reload.read_attribute(:balance), "the cache stores the new available balance"
  end

  test "holding a partly spent credit holds what is left of it" do
    wallet = points_wallet
    credit = wallet.credit(100, category: :reward)
    wallet.credit(50, category: :top_up)
    wallet.debit(30, category: :purchase) # oldest first: from the credit itself

    wallet.hold(credit, category: :fraud_review)

    assert_equal 70, credit.held_amount
    assert_equal [50, 70, 120], balances(wallet)
  end

  test "an already held credit takes another reason, counted once" do
    wallet = points_wallet
    credit = wallet.credit(100, category: :reward)
    fraud = wallet.hold(credit, category: :fraud_review)

    dispute = wallet.hold(credit, category: :dispute)

    refute_equal fraud, dispute
    assert_equal [fraud, dispute].map(&:id).sort, credit.holds.pluck(:id).sort
    assert_equal [0, 100, 100], balances(wallet)
  end

  test "a credit under a wallet hold can still be given its own reason" do
    wallet = points_wallet(100)
    wallet.hold(category: :chargeback)

    hold = wallet.hold(wallet.transactions.credits.sole, category: :fraud_review)

    assert hold.credit_scoped?
    assert_equal [0, 100, 100], balances(wallet)
  end

  test "a credit can be held until a deadline, and comes back at it on its own" do
    freeze_time
    wallet = points_wallet
    credit = wallet.credit(100, category: :reward)
    deadline = 3.days.from_now

    hold = wallet.hold(credit, category: :vesting, until: deadline)

    assert_equal deadline, hold.reload.releases_at
    travel_to(deadline - 1.second) { assert_equal [0, 100, 100], balances(wallet) }
    travel_to(deadline) do
      assert_equal [100, 0, 100], balances(wallet)
      assert hold.lapsed?
      refute hold.released?, "a deadline lapses a hold, it never releases it"
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # hold: the whole wallet
  # ───────────────────────────────────────────────────────────────────────────

  test "a hold without a credit holds the whole wallet, credits received later included" do
    wallet = points_wallet(100)

    hold = wallet.hold(category: :chargeback, metadata: {case_id: 7})

    assert hold.wallet_scoped?
    assert hold.coverage?
    assert_nil hold.credit
    assert_nil hold.amount
    assert wallet.on_hold?
    assert_equal [0, 100, 100], balances(wallet)

    later = wallet.credit(40, category: :reward)

    assert later.held?
    assert_equal [0, 140, 140], balances(wallet)
  end

  test "only leaving the credit out holds the whole wallet: an explicit nil is refused" do
    # A lookup that found nothing must not turn a hold on one credit into a
    # freeze on everything the owner has.
    wallet = points_wallet(100)
    not_found = wallet.transactions.find_by(id: -1)

    assert_no_holds_written(wallet) do
      error = assert_raises(ArgumentError) { wallet.hold(not_found, category: :fraud_review) }
      assert_equal "Pass no credit to hold the whole wallet; nil is not a credit", error.message
    end
    refute wallet.on_hold?

    assert wallet.hold(category: :fraud_review).wallet_scoped?
    assert wallet.on_hold?
  end

  test "an empty wallet can be put on hold" do
    wallet = points_wallet

    wallet.hold(category: :kyc_pending)

    assert wallet.on_hold?
    assert_equal [0, 0, 0], balances(wallet)
  end

  test "a wallet hold over a held credit and a reservation counts every unit once" do
    wallet = points_wallet
    credit = wallet.credit(100, category: :reward)
    wallet.credit(50, category: :top_up)
    wallet.hold(credit, category: :fraud_review)
    wallet.reserve(30, category: :booking)

    wallet.hold(category: :chargeback)

    assert_equal [-30, 180, 150], balances(wallet)
  end

  # ───────────────────────────────────────────────────────────────────────────
  # hold: deadlines
  # ───────────────────────────────────────────────────────────────────────────

  test "a deadline already reached is refused, the exact instant included" do
    freeze_time
    wallet = points_wallet
    credit = wallet.credit(100, category: :reward)

    [Time.current, 1.second.ago, 1.year.ago].each do |deadline|
      assert_no_holds_written(wallet) do
        error = assert_raises(Wallets::InvalidHold) { wallet.hold(credit, category: :review, until: deadline) }
        assert_match(/deadline must be in the future/, error.message)
        assert_raises(Wallets::InvalidHold) { wallet.hold(category: :review, until: deadline) }
      end
    end

    assert wallet.hold(credit, category: :review, until: 1.second.from_now).active?
  end

  test "a deadline is read the way the database column reads it" do
    # Strings and dates are read in Time.zone, as Active Record reads them
    # into a datetime column: the instant checked is the instant stored.
    freeze_time
    wallet = points_wallet(100)

    Time.use_zone("Madrid") do
      from_string = wallet.hold(category: :review, until: "2099-06-01 12:00")
      from_date = wallet.hold(category: :review, until: Date.new(2099, 6, 1))

      assert_equal Time.find_zone("Madrid").local(2099, 6, 1, 12), from_string.reload.releases_at
      assert_equal Time.find_zone("Madrid").local(2099, 6, 1), from_date.reload.releases_at
    end
  end

  test "a deadline that is not a time is refused instead of becoming no deadline" do
    wallet = points_wallet(100)

    ["soon", "", "2099-13-45", 42, 3.days, Object.new, :tomorrow].each do |deadline|
      assert_no_holds_written(wallet) do
        error = assert_raises(ArgumentError, "until: #{deadline.inspect} must be refused") do
          wallet.hold(category: :review, until: deadline)
        end
        assert_match(/until: must be a time/, error.message)
      end
    end
  end

  test "until: is the one spelling of a deadline" do
    wallet = points_wallet(100)

    assert_no_holds_written(wallet) do
      assert_raises(ArgumentError) { wallet.hold(category: :review, releases_at: 1.day.from_now) }
      assert_raises(ArgumentError) { wallet.reserve(10, category: :booking, releases_at: 1.day.from_now) }
      error = assert_raises(ArgumentError) { wallet.credit(5, category: :reward, hold: {category: :review, releases_at: 1.day.from_now}) }
      assert_equal "Unknown hold: options: releases_at", error.message
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # hold: what can be held
  # ───────────────────────────────────────────────────────────────────────────

  test "anything but a credit of this very wallet is a wrong argument" do
    # The same line `from:` draws: ArgumentError for what is not a credit of
    # this wallet, InvalidHold for a credit the ledger's state rules out.
    wallet = points_wallet
    credit = wallet.credit(100, category: :reward)
    debit = wallet.debit(10, category: :purchase)
    foreign = create_wallet(users(:peer_user), asset_code: :points, initial_balance: 100).transactions.sole

    {
      debit => /Transaction #{debit.id} is a debit: only credits can be held/,
      foreign => /Transaction #{foreign.id} belongs to another wallet/,
      Wallets::Transaction.new(wallet: wallet, amount: 10, category: :reward) => /Only a saved credit can be held/,
      credit.becomes(OtherLedgerTransaction) => /A hold covers a Wallets::Transaction, not .*OtherLedgerTransaction/,
      credit.id => /A hold covers a Wallets::Transaction, not Integer/,
      hold!(wallet) => /A hold covers a Wallets::Transaction, not Wallets::Hold/
    }.each do |target, message|
      assert_no_holds_written(wallet) do
        error = assert_raises(ArgumentError) { wallet.hold(target, category: :review) }
        assert_match message, error.message
      end
    end
  end

  test "a wrong argument is reported before a deadline already reached" do
    foreign = create_wallet(users(:peer_user), asset_code: :points, initial_balance: 100).transactions.sole

    error = assert_raises(ArgumentError) { points_wallet.hold(foreign, category: :review, until: 1.minute.ago) }
    assert_match(/belongs to another wallet/, error.message)
  end

  test "an expired credit cannot be held, from the exact instant it expires" do
    freeze_time
    wallet = points_wallet
    credit = wallet.credit(100, category: :reward, expires_at: 1.day.from_now)

    travel_to(1.day.from_now) do
      error = assert_raises(Wallets::InvalidHold) { wallet.hold(credit, category: :review) }
      assert_equal "Credit #{credit.id} has expired", error.message
    end
  end

  test "a credit with nothing left cannot be held" do
    wallet = points_wallet
    credit = wallet.credit(100, category: :reward)
    wallet.debit(100, category: :purchase)

    error = assert_raises(Wallets::InvalidHold) { wallet.hold(credit, category: :review) }

    assert_equal "Credit #{credit.id} has no remaining value to hold", error.message
    assert_empty credit.holds
  end

  test "what can be held is read from the ledger, never from the caller's copy" do
    wallet = points_wallet
    credit = wallet.credit(100, category: :reward)
    Wallets::Wallet.find(wallet.id).debit(100, category: :purchase) # spent through another copy

    assert_raises(Wallets::InvalidHold) { wallet.hold(credit, category: :review) }

    other = Wallets::Transaction.find(wallet.credit(5, category: :reward).id)
    other.expires_at = 1.day.ago # an unsaved change on the caller's copy only
    assert wallet.hold(other, category: :review).persisted?
    assert_nil other.reload.expires_at, "the caller's unsaved change is never written"
  end

  test "a credit removed from the ledger is a wrong argument" do
    wallet = points_wallet
    credit = wallet.credit(100, category: :reward)
    Wallets::Transaction.where(id: credit.id).delete_all

    error = assert_raises(ArgumentError) { wallet.hold(credit, category: :review) }
    assert_equal "Transaction #{credit.id} no longer exists", error.message
  end

  test "a hold needs a category" do
    wallet = points_wallet(100)

    [nil, "", "  "].each do |blank|
      assert_no_holds_written(wallet) do
        assert_raises(ActiveRecord::RecordInvalid) { wallet.hold(category: blank) }
      end
    end
    assert_raises(ArgumentError) { wallet.hold } # missing keyword
  end

  test "hold metadata is normalized like every other ledger metadata" do
    wallet = points_wallet(100)

    assert_equal({}, wallet.hold(category: :review, metadata: nil).reload.metadata)
    assert_equal({"case_id" => 7}, wallet.hold(category: :review, metadata: [[:case_id, 7]]).reload.metadata)
  end

  # ───────────────────────────────────────────────────────────────────────────
  # reserve
  # ───────────────────────────────────────────────────────────────────────────

  test "a reservation sets an amount of the available balance aside" do
    wallet = points_wallet(100)

    reservation = wallet.reserve(30, category: :booking, metadata: {booking_id: 9})

    assert_instance_of Wallets::Hold, reservation
    assert reservation.reservation?
    assert reservation.wallet_scoped?
    assert_equal 30, reservation.reload.amount
    assert_equal "booking", reservation.category
    assert_equal 9, reservation.metadata[:booking_id]
    assert_equal [70, 30, 100], balances(wallet)
    refute wallet.on_hold?, "a pending reservation is not a hold on the wallet"
    assert_equal 70, wallet.reload.read_attribute(:balance)
  end

  test "reservations add up, like pending card charges" do
    wallet = points_wallet(100)

    wallet.reserve(40, category: :booking)
    wallet.reserve(40, category: :booking)

    assert_equal [20, 80, 100], balances(wallet)
    assert_raises(Wallets::InsufficientBalance) { wallet.reserve(21, category: :booking) }
    wallet.reserve(20, category: :booking)
    assert_equal [0, 100, 100], balances(wallet)
  end

  test "a reservation must fit in the available balance" do
    wallet = points_wallet(100)
    wallet.hold(wallet.credit(50, category: :reward), category: :fraud_review)

    error = assert_no_holds_written(wallet) do
      assert_raises(Wallets::InsufficientBalance) { wallet.reserve(101, category: :booking) }
    end

    assert_equal "Insufficient balance (100 < 101; 50 held)", error.message
    assert wallet.reserve(100, category: :booking).persisted?, "exactly the available balance fits"
    assert_equal [0, 150, 150], balances(wallet)
  end

  test "with overdrafts on, a reservation may exceed the available balance" do
    Wallets.configuration.allow_negative_balance = true
    wallet = points_wallet(100)

    wallet.reserve(150, category: :booking)

    assert_equal [-50, 150, 100], balances(wallet)
  end

  test "under a wallet hold nothing is available to reserve unless overdrafts are on" do
    # Available is then -R - N: every credit is covered, so whatever is
    # reserved or owed already shows as a deficit.
    Wallets.configuration.allow_negative_balance = true
    wallet = points_wallet(100)
    wallet.debit(130, category: :purchase) # 100 from the credit, 30 unbacked
    wallet.credit(80, category: :top_up)
    wallet.reserve(20, category: :booking)
    wallet.hold(category: :chargeback)
    assert_equal(-20 - 30, wallet.balance)

    Wallets.configuration.allow_negative_balance = false
    assert_no_holds_written(wallet) do
      assert_raises(Wallets::InsufficientBalance) { wallet.reserve(1, category: :booking) }
    end

    Wallets.configuration.allow_negative_balance = true
    wallet.reserve(10, category: :booking)
    assert_equal(-30 - 30, wallet.balance)
    assert_equal [-60, 110, 50], balances(wallet)
  end

  test "a reservation leaves what remains spendable and nothing more" do
    wallet = points_wallet(100)
    wallet.reserve(80, category: :booking)

    assert_raises(Wallets::InsufficientBalance) { wallet.debit(21, category: :purchase) }
    wallet.debit(20, category: :purchase)

    assert_equal [0, 80, 80], balances(wallet)
  end

  test "a reservation lapses at its deadline and frees its amount" do
    freeze_time
    wallet = points_wallet(100)

    reservation = wallet.reserve(30, category: :booking, until: 7.days.from_now)

    assert_equal 7.days.from_now, reservation.reload.releases_at
    travel_to(7.days.from_now) { assert_equal [100, 0, 100], balances(wallet) }
  end

  test "a reservation deadline already reached is refused before funding is even considered" do
    freeze_time
    events = []
    Wallets.configuration.on_insufficient_balance { |context| events << context }
    wallet = points_wallet(10)

    assert_no_holds_written(wallet) do
      assert_raises(Wallets::InvalidHold) { wallet.reserve(30, category: :booking, until: Time.current) }
    end
    assert_empty events, "a malformed request is not a funding failure"
  end

  test "a reservation amount is a positive whole number, parsed exactly like a debit's" do
    wallet = points_wallet(100)

    [nil, 0, -5, 1.5, "ten", "25", Float::INFINITY].each do |amount|
      assert_no_holds_written(wallet) do
        assert_raises(ArgumentError, "amount #{amount.inspect} must be refused") { wallet.reserve(amount, category: :booking) }
        assert_raises(ArgumentError) { wallet.debit(amount, category: :purchase) }
      end
    end
    assert_equal 25, wallet.reserve(25.0, category: :booking).amount
  end

  # ───────────────────────────────────────────────────────────────────────────
  # release!
  # ───────────────────────────────────────────────────────────────────────────

  test "release! ends a hold now and records why, next to why it began" do
    freeze_time
    wallet = points_wallet
    credit = wallet.credit(100, category: :reward)
    hold = wallet.hold(credit, category: :fraud_review, metadata: {case_id: 42})

    travel 1.hour
    returned = hold.release!(reason: "cleared_by_operator", metadata: {actor_id: 12})

    assert_same hold, returned
    hold.reload
    assert_equal Time.current, hold.released_at
    assert_equal "cleared_by_operator", hold.release_reason
    assert_equal({"actor_id" => 12}, hold.release_metadata)
    assert_equal({"case_id" => 42}, hold.metadata, "creation facts are never overwritten")
    assert hold.released?
    refute hold.active?
    refute hold.lapsed?
    assert_equal [100, 0, 100], balances(wallet)
    assert_equal 100, wallet.reload.read_attribute(:balance)
  end

  test "releasing one reason keeps the credit held while another is active" do
    wallet = points_wallet
    credit = wallet.credit(100, category: :reward)
    fraud = wallet.hold(credit, category: :fraud_review)
    dispute = wallet.hold(credit, category: :dispute)

    fraud.release!
    assert_equal [0, 100, 100], balances(wallet)

    dispute.release!
    assert_equal [100, 0, 100], balances(wallet)
  end

  test "release! ends wallet holds and reservations alike" do
    wallet = points_wallet(100)
    reservation = wallet.reserve(30, category: :booking, until: 1.day.from_now)
    wallet_hold = wallet.hold(category: :chargeback)

    wallet_hold.release!(reason: :resolved)
    assert_equal [70, 30, 100], balances(wallet)
    refute wallet.on_hold?

    reservation.release!(reason: :cancelled)
    assert_equal [100, 0, 100], balances(wallet)
    assert_equal ["resolved", "cancelled"], [wallet_hold.reload.release_reason, reservation.reload.release_reason]
  end

  test "release! is idempotent: an ended hold is returned unchanged" do
    freeze_time
    wallet = points_wallet(100)
    hold = wallet.hold(category: :chargeback, metadata: {case_id: 1})
    hold.release!(reason: "first", metadata: {actor_id: 1})
    first_release = Wallets::Hold.find(hold.id).attributes

    travel 1.hour
    statements = capture_sql { assert_same hold, hold.release!(reason: "second", metadata: {actor_id: 2}) }

    assert_equal first_release, Wallets::Hold.find(hold.id).attributes
    assert_equal "first", hold.release_reason, "the caller's copy shows the release that happened"
    assert statements.none? { |sql| sql.match?(/\A\s*(INSERT|UPDATE|DELETE)/i) }, "a no-op writes nothing:\n#{statements.join("\n")}"
  end

  test "release! leaves a lapsed hold lapsed" do
    freeze_time
    wallet = points_wallet(100)
    hold = wallet.hold(category: :chargeback, until: 1.day.from_now)

    travel 2.days
    hold.release!(reason: "too late")

    hold.reload
    assert hold.lapsed?
    refute hold.released?
    assert_nil hold.released_at
    assert_nil hold.release_reason
    assert_equal({}, hold.release_metadata)
  end

  test "release! leaves a captured reservation captured" do
    wallet = points_wallet(100)
    debit = wallet.debit(40, category: :purchase)
    captured = reservation!(wallet, 40, released_at: 1.minute.ago, release_reason: "captured", capture_transaction: debit)
    before = captured.reload.attributes

    captured.release!(reason: "operator")

    assert_equal before, captured.reload.attributes
    assert captured.captured?
  end

  test "release! sees a release that happened through another copy of the hold" do
    wallet = points_wallet(100)
    hold = wallet.hold(category: :chargeback)
    Wallets::Hold.find(hold.id).release!(reason: "elsewhere")

    hold.release!(reason: "here")

    assert_equal "elsewhere", hold.release_reason
    assert_equal "elsewhere", hold.reload.release_reason
  end

  test "release! locks the wallet before it reads the hold" do
    wallet = points_wallet(100)
    hold = Wallets::Hold.find(wallet.hold(category: :chargeback).id)
    hold.wallet # loaded up front, so only the release's own reads are captured

    statements = capture_sql { hold.release! }

    wallet_lock = statements.index { |sql| sql.match?(/\ASELECT .* FROM .?wallets_wallets.? .*#{"FOR UPDATE" unless sqlite?}/i) }
    hold_read = statements.index { |sql| sql.match?(/\ASELECT .* FROM .?wallets_holds.? /i) }
    assert wallet_lock, "the wallet is locked:\n#{statements.join("\n")}"
    assert_operator wallet_lock, :<, hold_read, "wallet first, then the hold"
    assert_match(/FOR UPDATE/, statements[hold_read], "the hold is read as it is now") unless sqlite?
  end

  test "a set of holds is released by ordinary composition under the wallet lock" do
    wallet = points_wallet(100)
    holds = [wallet.reserve(10, category: :booking), wallet.hold(category: :chargeback)]

    wallet.with_lock { holds.each(&:release!) }

    assert holds.all? { |hold| hold.reload.released? }
    assert_equal [100, 0, 100], balances(wallet)
  end

  test "release metadata is normalized and the reason is optional" do
    wallet = points_wallet(100)
    hold = wallet.hold(category: :chargeback)

    hold.release!(metadata: nil)

    assert_nil hold.reload.release_reason
    assert_equal({}, hold.release_metadata)
  end

  test "only a saved hold can be released" do
    hold = Wallets::Hold.new(wallet: points_wallet, category: :review)

    error = assert_raises(Wallets::InvalidHold) { hold.release! }
    assert_equal "Only a saved hold can be released", error.message
  end

  # ───────────────────────────────────────────────────────────────────────────
  # credit(hold:) and credit(available_at:)
  # ───────────────────────────────────────────────────────────────────────────

  test "a credit can arrive held, under a category" do
    wallet = points_wallet(10)

    credit = wallet.credit(751, category: :reward, hold: :pending_validation)

    assert_instance_of Wallets::Transaction, credit
    hold = credit.holds.sole
    assert_equal "pending_validation", hold.category
    assert_equal wallet, hold.wallet
    assert hold.credit_scoped?
    assert_nil hold.releases_at
    assert_equal({}, hold.metadata)
    assert_equal [10, 751, 761], balances(wallet)
    assert_equal [10, 10], [credit.balance_before, credit.balance_after], "never spendable, not even for an instant"
    assert_equal 10, wallet.reload.read_attribute(:balance)
  end

  test "a credit can arrive held with a deadline and its own metadata" do
    freeze_time
    wallet = points_wallet

    credit = wallet.credit(751, category: :reward, metadata: {ride_id: 1},
      hold: {category: :pending_validation, until: 3.months.from_now, metadata: {case: "c-1"}})

    hold = credit.holds.sole
    assert_equal 3.months.from_now, hold.releases_at
    assert_equal({"case" => "c-1"}, hold.metadata)
    assert_equal({"ride_id" => 1}, credit.metadata.except("balance_before", "balance_after"))
    travel_to(3.months.from_now) { assert_equal [751, 0, 751], balances(wallet) }
  end

  test "hold: takes a String category and string keys too" do
    wallet = points_wallet

    assert_equal "pending", wallet.credit(5, category: :reward, hold: "pending").holds.sole.category
    from_strings = wallet.credit(5, category: :reward, hold: {"category" => "review", "until" => 1.day.from_now})
    assert_equal "review", from_strings.holds.sole.category
    assert from_strings.holds.sole.releases_at.present?
  end

  test "available_at: holds the credit as pending until then" do
    freeze_time
    wallet = points_wallet

    credit = wallet.credit(500, category: :reward, available_at: 14.days.from_now)

    hold = credit.holds.sole
    assert_equal "pending", hold.category
    assert_equal 14.days.from_now, hold.releases_at
    assert_equal [0, 500, 500], balances(wallet)
    travel_to(14.days.from_now) { assert_equal [500, 0, 500], balances(wallet) }
  end

  test "available_at: already reached means available now, with no hold at all" do
    freeze_time
    wallet = points_wallet

    [Time.current, 1.day.ago].each do |reached|
      credit = wallet.credit(100, category: :reward, available_at: reached)

      assert_empty credit.holds
    end
    assert_equal [200, 0, 200], balances(wallet)
  end

  test "hold: and available_at: together are refused before anything is written" do
    wallet = points_wallet

    assert_nothing_written(wallet) do
      error = assert_raises(ArgumentError) { wallet.credit(5, category: :reward, hold: :review, available_at: 1.day.from_now) }
      assert_equal "Pass hold: or available_at:, not both", error.message
    end
  end

  test "a malformed hold: is refused before anything is written" do
    wallet = points_wallet

    {
      true => /hold: takes a category or a Hash/,
      42 => /hold: takes a category or a Hash/,
      [:review] => /hold: takes a category or a Hash/,
      {category: :review, amount: 5} => /Unknown hold: options: amount/,
      {until: 1.day.from_now} => /hold: needs a category/,
      {category: :review, until: "soon"} => /until: must be a time/
    }.each do |hold, message|
      assert_nothing_written(wallet) do
        error = assert_raises(ArgumentError, "hold: #{hold.inspect} must be refused") { wallet.credit(5, category: :reward, hold: hold) }
        assert_match message, error.message
      end
    end

    assert_nothing_written(wallet) do
      error = assert_raises(ArgumentError) { wallet.credit(5, category: :reward, available_at: "whenever") }
      assert_match(/available_at: must be a time/, error.message)
    end
  end

  test "a hold: deadline already reached is refused before the credit is written" do
    freeze_time
    wallet = points_wallet

    assert_nothing_written(wallet) do
      assert_raises(Wallets::InvalidHold) { wallet.credit(5, category: :reward, hold: {category: :review, until: Time.current}) }
    end
  end

  test "a credit that cannot get its hold is never written, even when the caller rescues and commits" do
    wallet = points_wallet(10)

    Wallets::Wallet.transaction do
      assert_raises(ActiveRecord::RecordInvalid) { wallet.credit(751, category: :reward, hold: {category: "  "}) }
      wallet.credit(5, category: :top_up) # the caller's transaction is still usable
    end

    assert_equal [10, 5], wallet.transactions.order(:id).pluck(:amount)
    assert_empty Wallets::Hold.where(wallet: wallet)
    assert_equal [15, 0, 15], balances(wallet)
  end

  test "a credit whose hold the database refuses is rolled back with it, even when the caller rescues and commits" do
    # The shape of a real database failure: on PostgreSQL it aborts the
    # transaction it ran in, so only a savepoint lets the caller carry on.
    wallet = points_wallet(10)
    Wallets::Hold.define_singleton_method(:create!) do |**attributes|
      new(**attributes, amount: 0).tap { |hold| hold.save!(validate: false) } # violates a check constraint
    end

    begin
      Wallets::Wallet.transaction do
        assert_raises(ActiveRecord::StatementInvalid) { wallet.credit(751, category: :reward, hold: :review) }
        wallet.credit(5, category: :top_up)
      end
    ensure
      Wallets::Hold.singleton_class.send(:remove_method, :create!)
    end

    assert_equal [10, 5], wallet.transactions.order(:id).pluck(:amount)
    assert_equal [15, 0, 15], balances(wallet)
  end

  test "a credit can arrive held into a wallet that is already on hold" do
    wallet = points_wallet(100)
    wallet.hold(category: :chargeback)

    credit = wallet.credit(50, category: :reward, hold: :pending_validation)

    assert_equal 1, credit.holds.count
    assert_equal [0, 150, 150], balances(wallet)
  end

  test "a credit arriving held still expires on its own schedule" do
    freeze_time
    wallet = points_wallet

    wallet.credit(100, category: :reward, expires_at: 10.days.from_now, available_at: 30.days.from_now)

    travel_to(10.days.from_now) { assert_equal [0, 0, 0], balances(wallet) }
  end

  test "an ordinary credit is unchanged by the new keywords" do
    wallet = points_wallet

    credit = wallet.credit(100, category: :reward)

    assert_empty credit.holds
    assert_equal [100, 0, 100], balances(wallet)
  end

  # ───────────────────────────────────────────────────────────────────────────
  # One instant, one savepoint, one wallet write per command
  # ───────────────────────────────────────────────────────────────────────────

  test "hold reads the ledger at the one instant it sampled under the lock" do
    travel_to Time.utc(2030, 1, 1, 12)
    wallet = points_wallet
    credit = wallet.credit(100, category: :reward, expires_at: 1.second.from_now)
    sampled = Time.current
    Time.stubs(:current).returns(sampled).then.returns(sampled + 1.minute)

    hold = wallet.hold(credit, category: :review, until: sampled + 30.seconds)

    assert hold.persisted?, "the credit was unexpired and the deadline ahead at the sampled instant"
    assert_equal 100, hold.credit.held_amount(at: sampled)
  end

  test "release! stamps the instant it sampled under the lock" do
    travel_to Time.utc(2030, 1, 1, 12)
    wallet = points_wallet(100)
    hold = wallet.hold(category: :chargeback, until: 10.seconds.from_now)
    sampled = Time.current
    Time.stubs(:current).returns(sampled).then.returns(sampled + 1.minute)

    hold.release!(reason: "cleared")

    assert_equal sampled, hold.reload.released_at
    assert hold.released?, "active at the sampled instant, so released rather than left to lapse"
  end

  test "a credit decides available_at: at the instant it sampled under the lock" do
    travel_to Time.utc(2030, 1, 1, 12)
    wallet = points_wallet
    sampled = Time.current
    Time.stubs(:current).returns(sampled).then.returns(sampled + 1.minute)

    credit = wallet.credit(100, category: :reward, available_at: sampled + 30.seconds)

    assert_equal 1, credit.holds.count
    assert_equal [0, 0], [credit.balance_before, credit.balance_after]
  end

  test "every hold command writes the wallet row, even when the available balance does not move" do
    # How a stale snapshot is told from a current one (MySQL).
    wallet = points_wallet
    credit = wallet.credit(100, category: :reward)
    first = wallet.hold(credit, category: :fraud_review)

    {
      "a second reason" => -> { wallet.hold(credit, category: :dispute) },
      "releasing one of two reasons" => -> { first.release! },
      "a credit arriving held" => -> { wallet.credit(5, category: :reward, hold: :review) },
      "a wallet hold over held value" => -> { wallet.hold(category: :chargeback) }
    }.each_with_index do |(description, command), index|
      before = wallet.reload.updated_at
      travel(index + 1) { command.call }
      assert_operator wallet.reload.updated_at, :>, before, "#{description} must write the wallet row"
    end
  end

  test "a hold that fails after its row is written leaves nothing behind, even when the caller rescues and commits" do
    wallet = points_wallet(100)
    wallet.stubs(:refresh_cached_balance!).raises(ActiveRecord::StatementInvalid, "boom")

    Wallets::Wallet.transaction do
      assert_raises(ActiveRecord::StatementInvalid) { wallet.hold(category: :chargeback) }
      assert_raises(ActiveRecord::StatementInvalid) { wallet.reserve(10, category: :booking) }
    end

    assert_empty Wallets::Hold.where(wallet: wallet)
  end

  test "a release that fails after its write leaves the hold active, even when the caller rescues and commits" do
    wallet = points_wallet(100)
    hold = wallet.hold(category: :chargeback)
    hold.wallet.stubs(:refresh_cached_balance!).raises(ActiveRecord::StatementInvalid, "boom")

    Wallets::Wallet.transaction do
      assert_raises(ActiveRecord::StatementInvalid) { hold.release! }
    end

    assert Wallets::Hold.find(hold.id).active?
  end

  test "a release that fails after its write leaves the caller's hold reading active" do
    # Active Record would leave the copy holding the rolled-back release,
    # with no unsaved changes to give it away.
    wallet = points_wallet(100)
    hold = wallet.hold(category: :chargeback, metadata: {case_id: 1})
    hold.wallet.stubs(:refresh_cached_balance!).raises(ActiveRecord::StatementInvalid, "boom")

    Wallets::Wallet.transaction do
      assert_raises(ActiveRecord::StatementInvalid) { hold.release!(reason: "cleared", metadata: {actor_id: 7}) }
    end

    assert hold.active?
    refute hold.released?
    assert_nil hold.released_at
    assert_nil hold.release_reason
    assert_equal({}, hold.release_metadata)
    assert_equal({"case_id" => 1}, hold.metadata)
    refute hold.has_changes_to_save?

    hold.wallet.unstub(:refresh_cached_balance!)
    hold.release!(reason: "cleared")
    assert_equal "cleared", hold.reload.release_reason, "and it can be released again"
  end

  test "the pinned instant is released after every hold command, even a failing one" do
    wallet = points_wallet(10)

    wallet.hold(category: :chargeback)
    assert_raises(Wallets::InsufficientBalance) { wallet.reserve(50, category: :booking) }

    assert_nil wallet.instance_variable_get(:@evaluation_time)
    travel 1.day do
      assert_equal Time.current, wallet.send(:evaluation_time)
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

  def sqlite?
    Wallets::Wallet.connection.adapter_name.match?(/sqlite/i)
  end

  def assert_no_holds_written(wallet, &block)
    assert_no_difference(-> { Wallets::Hold.where(wallet_id: wallet.id).count }, &block)
  end

  def assert_nothing_written(wallet, &block)
    assert_no_changes(-> { [Wallets::Hold.where(wallet_id: wallet.id).count, wallet.transactions.count] }, &block)
  end
end
