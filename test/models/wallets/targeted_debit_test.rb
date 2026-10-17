# frozen_string_literal: true

require "test_helper"

# Targeted debits and transfers: `debit(..., from:)` and
# `transfer_to(..., from:)`. They are allocated to the named credits only, in
# the caller's order, in full or not at all, and they are the one way to take
# value a hold covers. Their callbacks are pinned in WalletCallbacksTest,
# their races in CurrentReadsTest, a ledger without holds in
# EmbeddabilityTest.
class Wallets::TargetedDebitTest < ActiveSupport::TestCase
  # Same table and row as Wallets::Transaction, yet another ledger's class.
  class OtherLedgerTransaction < Wallets::Transaction
  end

  setup do
    @owner = users(:new_user)
    Wallets.configuration.additional_categories = Wallets.configuration.additional_categories + %w[reversal]
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Cancelling held value
  # ───────────────────────────────────────────────────────────────────────────

  test "a fully held credit is cancelled at zero available, and its reasons stay readable" do
    wallet = points_wallet
    credit = wallet.credit(751, category: :reward, hold: :pending_validation)
    assert_equal [0, 751, 751], balances(wallet)

    spend = wallet.debit(751, category: :reversal, from: credit, metadata: {reason: "reward_rejected"})

    assert_equal [[credit.id, 751]], allocations(spend)
    assert_equal 0, spend.unbacked_amount
    assert_equal [0, 0, 0], balances(wallet)
    assert_equal 0, credit.reload.remaining_amount
    assert_equal 0, credit.held_amount, "nothing is left to hold"
    refute credit.held?

    reason = credit.holds.sole
    assert reason.active?, "the hold was not released: it simply has nothing left to hold"
    refute reason.released?
    assert_equal "pending_validation", reason.category
    assert_equal [reason], credit.holds.active.to_a

    assert_equal [0, 0], [spend.balance_before, spend.balance_after], "available never moved"
    assert_equal "reward_rejected", spend.metadata[:reason]
    assert_equal 0, wallet.reload.read_attribute(:balance)
  end

  test "part of a held credit can be cancelled, and the rest stays held" do
    wallet = points_wallet
    credit = wallet.credit(100, category: :reward)
    wallet.credit(30, category: :top_up)
    wallet.hold(credit, category: :fraud_review)

    wallet.debit(40, category: :reversal, from: credit)

    assert_equal 60, credit.reload.held_amount
    assert_equal [30, 60, 90], balances(wallet)
  end

  test "value a wallet hold covers can be cancelled too" do
    wallet = points_wallet
    credit = wallet.credit(100, category: :reward)
    hold = wallet.hold(category: :chargeback)

    spend = wallet.debit(100, category: :reversal, from: credit)

    assert_equal [[credit.id, 100]], allocations(spend)
    assert_equal [0, 0, 0], balances(wallet)
    assert wallet.on_hold?, "the wallet hold stands"
    assert hold.reload.active?
  end

  test "held value is cancelled even while reservations leave nothing available" do
    wallet = points_wallet
    free = wallet.credit(100, category: :top_up)
    held = wallet.credit(50, category: :reward, hold: :fraud_review)
    wallet.reserve(100, category: :booking)
    assert_equal [0, 150, 150], balances(wallet)

    wallet.debit(50, category: :reversal, from: held)

    assert_equal [0, 100, 100], balances(wallet)
    assert_equal 100, free.reload.remaining_amount, "the reserved value is still backed"
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Funding: unheld value still needs it (overdrafts off)
  # ───────────────────────────────────────────────────────────────────────────

  test "naming an unheld credit cannot spend what a reservation set aside" do
    wallet = points_wallet
    credit = wallet.credit(100, category: :top_up)
    reservation = wallet.reserve(100, category: :booking)

    error = assert_nothing_written(wallet) do
      assert_raises(Wallets::InsufficientBalance) { wallet.debit(40, category: :purchase, from: credit) }
    end

    assert_equal "Insufficient balance (0 < 40; 100 reserved)", error.message
    assert reservation.reload.active?
    assert_equal [0, 100, 100], balances(wallet)
  end

  test "an unheld credit can be named for what is available, and not a unit more" do
    wallet = points_wallet
    credit = wallet.credit(100, category: :top_up)
    wallet.reserve(30, category: :booking)

    assert_raises(Wallets::InsufficientBalance) { wallet.debit(71, category: :purchase, from: credit) }
    spend = wallet.debit(70, category: :purchase, from: credit)

    assert_equal [[credit.id, 70]], allocations(spend)
    assert_equal [0, 30, 30], balances(wallet)
  end

  test "a targeted debit cannot deepen an existing deficit, yet can still cancel held value" do
    wallet = points_wallet
    free = wallet.credit(10, category: :top_up)
    held = wallet.credit(100, category: :reward, hold: :fraud_review)
    Wallets.configuration.allow_negative_balance = true
    wallet.debit(40, category: :purchase) # 10 from the free credit, 30 unbacked
    Wallets.configuration.allow_negative_balance = false
    assert_equal [-30, 100, 70], balances(wallet)

    wallet.debit(10, category: :reversal, from: held)
    assert_equal [-30, 90, 60], balances(wallet), "cancelling held value leaves the deficit where it was"

    later = wallet.credit(20, category: :top_up)
    assert_equal(-10, wallet.balance)
    error = assert_nothing_written(wallet) do
      assert_raises(Wallets::InsufficientBalance) { wallet.debit(5, category: :purchase, from: later) }
    end
    assert_equal "Insufficient balance (-10 < 5; 90 held)", error.message
    assert_equal 0, free.reload.remaining_amount
  end

  test "held value counts against the debit, and only the rest needs funding" do
    wallet = points_wallet
    held = wallet.credit(50, category: :reward, hold: :fraud_review)
    free = wallet.credit(100, category: :top_up)
    wallet.reserve(90, category: :booking) # 10 available

    error = assert_nothing_written(wallet) do
      assert_raises(Wallets::InsufficientBalance) { wallet.debit(61, category: :reversal, from: [held, free]) }
    end
    assert_equal "Insufficient balance (10 < 61 - 50 from held credits; 50 held, 90 reserved)", error.message

    spend = wallet.debit(60, category: :reversal, from: [held, free])

    assert_equal [[held.id, 50], [free.id, 10]], allocations(spend)
    assert_equal [0, 90, 90], balances(wallet)
  end

  test "the caller's order decides which part counts as held" do
    # The same two credits in the other order: the unheld one gives all 60,
    # and 60 does not fit in the 10 available.
    wallet = points_wallet
    held = wallet.credit(50, category: :reward, hold: :fraud_review)
    free = wallet.credit(100, category: :top_up)
    wallet.reserve(90, category: :booking)

    assert_raises(Wallets::InsufficientBalance) { wallet.debit(60, category: :reversal, from: [free, held]) }
    assert_equal 0, wallet.transactions.debits.count
  end

  test "with overdrafts on, named credits may be spent past what is available" do
    Wallets.configuration.allow_negative_balance = true
    wallet = points_wallet
    credit = wallet.credit(100, category: :top_up)
    wallet.reserve(100, category: :booking)

    spend = wallet.debit(40, category: :purchase, from: credit)

    assert_equal [[credit.id, 40]], allocations(spend)
    assert_equal 0, spend.unbacked_amount
    assert_equal [-40, 100, 60], balances(wallet)
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Allocation: the named credits, in the caller's order, in full
  # ───────────────────────────────────────────────────────────────────────────

  test "named credits are spent in the caller's order, not soonest-expiring first" do
    wallet = points_wallet
    evergreen = wallet.credit(30, category: :top_up)
    expiring = wallet.credit(50, category: :reward, expires_at: 2.days.from_now)
    held = wallet.credit(100, category: :reward, hold: :fraud_review)

    spend = wallet.debit(160, category: :reversal, from: [held, evergreen, expiring])

    assert_equal [[held.id, 100], [evergreen.id, 30], [expiring.id, 30]], allocations(spend), "the allocations name the sources, in order"
    assert_equal [0, 0, 20], [held, evergreen, expiring].map { |credit| credit.reload.remaining_amount }
    assert_equal [20, 0, 20], balances(wallet)
  end

  test "a named credit with nothing left gives nothing, and the next one carries on" do
    wallet = points_wallet
    spent = wallet.credit(20, category: :top_up)
    wallet.debit(20, category: :purchase)
    credit = wallet.credit(50, category: :top_up)

    spend = wallet.debit(30, category: :purchase, from: [spent, credit])

    assert_equal [[credit.id, 30]], allocations(spend)
  end

  test "a debit beyond what the named credits hold is refused, even with overdrafts on" do
    # No falling back to other credits, and no debt: other value in the
    # wallet, and the flag, change nothing.
    Wallets.configuration.allow_negative_balance = true
    wallet = points_wallet
    credit = wallet.credit(100, category: :reward, hold: :fraud_review)
    wallet.credit(500, category: :top_up)

    error = assert_nothing_written(wallet) do
      assert_raises(Wallets::InsufficientBalance) { wallet.debit(101, category: :reversal, from: credit) }
    end

    assert_equal "Insufficient balance (100 < 101 in the named credits; 100 held)", error.message
    assert_equal [500, 100, 600], balances(wallet)
  end

  test "a credit spent through another copy has only what is left of it to give" do
    wallet = points_wallet
    credit = wallet.credit(100, category: :top_up)
    Wallets::Wallet.find(wallet.id).debit(70, category: :purchase)

    error = assert_raises(Wallets::InsufficientBalance) { wallet.debit(31, category: :purchase, from: credit) }

    assert_equal "Insufficient balance (30 < 31 in the named credits)", error.message
    assert_equal [[credit.id, 30]], allocations(wallet.debit(30, category: :purchase, from: credit))
  end

  test "named credits are read from the ledger, never from the caller's copy" do
    wallet = points_wallet
    credit = Wallets::Transaction.find(wallet.credit(100, category: :top_up).id)
    credit.expires_at = 1.day.ago # an unsaved change on the caller's copy only

    spend = wallet.debit(10, category: :purchase, from: credit)

    assert_equal [[credit.id, 10]], allocations(spend)
    assert_nil credit.reload.expires_at, "the caller's unsaved change is never written"
  end

  # ───────────────────────────────────────────────────────────────────────────
  # What can be named
  # ───────────────────────────────────────────────────────────────────────────

  test "from: names saved, distinct credits of this very wallet and ledger" do
    wallet = points_wallet
    credit = wallet.credit(100, category: :reward)
    debit = wallet.debit(10, category: :purchase)
    foreign = create_wallet(users(:peer_user), asset_code: :points, initial_balance: 100).transactions.sole
    removed = wallet.credit(5, category: :reward)
    Wallets::Transaction.where(id: removed.id).delete_all

    {
      nil => "from: is nil; leave it out to spend any eligible credit",
      [] => "from: names no credit",
      [credit, credit] => "from: names transaction #{credit.id} more than once",
      [credit, Wallets::Transaction.find(credit.id)] => "from: names transaction #{credit.id} more than once",
      debit => "Transaction #{debit.id} is a debit: only credits can fund a targeted debit",
      [credit, debit] => "Transaction #{debit.id} is a debit: only credits can fund a targeted debit",
      foreign => "Transaction #{foreign.id} belongs to another wallet",
      removed => "Transaction #{removed.id} no longer exists",
      credit.becomes(OtherLedgerTransaction) => "from: takes Wallets::Transaction credits, not #{OtherLedgerTransaction.name}",
      credit.id => "from: takes Wallets::Transaction credits, not Integer",
      [credit, nil] => "from: takes Wallets::Transaction credits, not NilClass",
      {credit: credit} => "from: takes Wallets::Transaction credits, not Hash",
      wallet.hold(category: :review) => "from: takes Wallets::Transaction credits, not Wallets::Hold",
      Wallets::Transaction.new(wallet: wallet, amount: 10, category: :reward) => "from: takes saved credits only"
    }.each do |from, message|
      assert_nothing_written(wallet) do
        error = assert_raises(ArgumentError, "from: #{from.inspect} must be refused") { wallet.debit(1, category: :purchase, from: from) }
        assert_equal message, error.message
      end
    end
  end

  test "a list of credits may be any list, a relation included, and keeps its order" do
    wallet = points_wallet
    first = wallet.credit(10, category: :top_up)
    second = wallet.credit(10, category: :top_up)

    spend = wallet.debit(15, category: :purchase, from: wallet.transactions.credits.order(id: :desc))

    assert_equal [[second.id, 10], [first.id, 5]], allocations(spend)
  end

  test "an expired credit gives nothing, from the exact instant it expires, like a spent one" do
    freeze_time
    wallet = points_wallet
    expiring = wallet.credit(100, category: :reward, expires_at: 1.day.from_now)
    evergreen = wallet.credit(100, category: :top_up)

    travel_to(1.day.from_now) do
      assert_nothing_written(wallet) do
        error = assert_raises(Wallets::InsufficientBalance) { wallet.debit(10, category: :purchase, from: expiring) }
        assert_equal "Insufficient balance (0 < 10 in the named credits)", error.message
      end

      [[expiring, evergreen], [evergreen, expiring]].each do |from|
        spend = wallet.debit(10, category: :purchase, from: from)
        assert_equal [[evergreen.id, 10]], allocations(spend), "the expired credit is passed over"
      end
    end

    travel_to(1.day.from_now - 1.second) do
      assert_equal [[expiring.id, 10]], allocations(wallet.debit(10, category: :purchase, from: expiring))
    end
  end

  test "no allocation ever points at an expired named credit, so no value is created from it" do
    freeze_time
    Wallets.configuration.allow_negative_balance = true # and no falling back to debt either
    sender = points_wallet
    expired = sender.credit(100, category: :reward, expires_at: 1.day.from_now, hold: :fraud_review)
    live = sender.credit(30, category: :top_up)
    recipient = create_wallet(users(:peer_user), asset_code: :points)
    travel 1.day

    sender.debit(10, category: :purchase, from: [expired, live])
    sender.transfer_to(recipient, 20, category: :peer_payment, from: [live, expired])
    assert_raises(Wallets::InsufficientBalance) { sender.debit(1, category: :purchase, from: [expired, live]) }
    [{}, {expiration_policy: :none}, {expires_at: 10.days.from_now}].each do |policy|
      assert_raises(Wallets::InsufficientBalance) { sender.transfer_to(recipient, 1, category: :peer_payment, from: expired, **policy) }
    end

    assert_empty Wallets::Allocation.where(source_transaction_id: expired.id)
    assert_equal 100, expired.reload.remaining_amount, "what it held when it expired, untouched"
    assert_equal 0, live.reload.remaining_amount
    assert sender.transactions.debits.all? { |debit| debit.unbacked_amount.zero? }
    assert_equal [0, 0, 0], balances(sender)
    assert_equal [20, 0, 20], balances(recipient), "the recipient got only what the live credit gave"
  end

  test "a targeted debit decides expiry at the instant it sampled under the lock" do
    travel_to Time.utc(2030, 1, 1, 12)
    wallet = points_wallet
    credit = wallet.credit(100, category: :reward, expires_at: 1.second.from_now)
    sampled = Time.current
    Time.stubs(:current).returns(sampled).then.returns(sampled + 1.minute)

    spend = wallet.debit(60, category: :purchase, from: credit)

    assert_equal [[credit.id, 60]], allocations(spend)
    assert_equal [100, 40], [spend.balance_before, spend.balance_after]
  end

  test "an amount is a positive whole number, parsed exactly like any debit's" do
    wallet = points_wallet
    credit = wallet.credit(100, category: :top_up)

    [nil, 0, -5, 1.5, "ten"].each do |amount|
      assert_nothing_written(wallet) do
        assert_raises(ArgumentError, "amount #{amount.inspect} must be refused") { wallet.debit(amount, category: :purchase, from: credit) }
      end
    end
  end

  test "an ordinary debit is unchanged, and leaving from: out still never touches held value" do
    wallet = points_wallet
    held = wallet.credit(100, category: :reward, hold: :fraud_review)
    free = wallet.credit(30, category: :top_up)

    spend = wallet.debit(30, category: :purchase)

    assert_equal [[free.id, 30]], allocations(spend)
    assert_raises(Wallets::InsufficientBalance) { wallet.debit(1, category: :purchase) }
    assert_equal 100, held.reload.remaining_amount
  end

  # ───────────────────────────────────────────────────────────────────────────
  # One savepoint, one wallet write
  # ───────────────────────────────────────────────────────────────────────────

  test "a refused targeted debit leaves the caller's transaction usable" do
    wallet = points_wallet
    credit = wallet.credit(100, category: :top_up)
    wallet.reserve(100, category: :booking)

    Wallets::Wallet.transaction do
      assert_raises(Wallets::InsufficientBalance) { wallet.debit(10, category: :purchase, from: credit) }
      wallet.credit(5, category: :top_up)
    end

    assert_equal [5, 100, 105], balances(wallet)
  end

  test "a targeted debit that fails after its writes leaves nothing behind, even when the caller rescues and commits" do
    wallet = points_wallet
    credit = wallet.credit(100, category: :reward, hold: :fraud_review)
    wallet.stubs(:refresh_cached_balance!).raises(ActiveRecord::StatementInvalid, "boom")

    Wallets::Wallet.transaction do
      assert_raises(ActiveRecord::StatementInvalid) { wallet.debit(100, category: :reversal, from: credit) }
    end

    assert_empty wallet.transactions.debits
    assert_equal 100, credit.reload.remaining_amount
  end

  test "cancelling held value writes the wallet row, though the available balance does not move" do
    wallet = points_wallet
    credit = wallet.credit(100, category: :reward, hold: :fraud_review)
    before = wallet.reload.updated_at

    travel(1.second) { wallet.debit(100, category: :reversal, from: credit) }

    assert_operator wallet.reload.updated_at, :>, before
  end

  # ───────────────────────────────────────────────────────────────────────────
  # transfer_to(..., from:)
  # ───────────────────────────────────────────────────────────────────────────

  test "a targeted transfer at zero available keeps its sources' expirations, in the caller's order" do
    sender = points_wallet
    soon = 10.days.from_now.change(usec: 0)
    late = 30.days.from_now.change(usec: 0)
    early = sender.credit(50, category: :reward, expires_at: soon, hold: :fraud_review)
    later = sender.credit(100, category: :reward, expires_at: late, hold: :fraud_review)
    recipient = create_wallet(users(:peer_user), asset_code: :points)
    assert_equal 0, sender.balance

    transfer = sender.transfer_to(recipient, 120, category: :peer_payment, from: [later, early])

    assert_equal "preserve", transfer.expiration_policy
    outbound = transfer.outbound_transaction
    assert_equal 0, outbound.unbacked_amount
    assert_equal [[later.id, 100], [early.id, 20]], allocations(outbound)
    assert_equal [[100, late], [20, soon]], transfer.inbound_transactions.order(:id).map { |credit| [credit.amount, credit.expires_at] }
    assert_equal [0, 30, 30], balances(sender)
    assert_equal [120, 0, 120], balances(recipient)
    assert_equal [0, 0], [outbound.balance_before, outbound.balance_after]
  end

  test "a targeted transfer honours :none and :fixed on the inbound side" do
    sender = points_wallet
    credit = sender.credit(100, category: :reward, expires_at: 30.days.from_now, hold: :fraud_review)
    recipient = create_wallet(users(:peer_user), asset_code: :points)
    fixed = 5.days.from_now.change(usec: 0)

    evergreen = sender.transfer_to(recipient, 40, category: :peer_payment, from: credit, expiration_policy: :none)
    dated = sender.transfer_to(recipient, 40, category: :peer_payment, from: credit, expires_at: fixed)

    assert_equal [["none", nil], ["fixed", fixed]], [evergreen, dated].map { |transfer| [transfer.expiration_policy, transfer.inbound_transactions.sole.expires_at] }
    assert_equal 20, credit.reload.remaining_amount
  end

  test "a targeted transfer passes over an expired source under every expiration policy" do
    freeze_time
    sender = points_wallet
    expiring = sender.credit(100, category: :reward, expires_at: 1.day.from_now)
    evergreen = sender.credit(100, category: :top_up)
    recipient = create_wallet(users(:peer_user), asset_code: :points)

    travel_to(1.day.from_now) do
      [{}, {expiration_policy: :preserve}, {expiration_policy: :none}, {expires_at: 10.days.from_now}].each do |policy|
        assert_no_difference -> { Wallets::Transfer.count } do
          assert_nothing_written(sender) do
            error = assert_raises(Wallets::InsufficientBalance, "#{policy.inspect}: an expired source alone funds nothing") do
              sender.transfer_to(recipient, 10, category: :peer_payment, from: expiring, **policy)
            end
            assert_equal "Insufficient balance (0 < 10 in the named credits)", error.message
          end
        end

        transfer = sender.transfer_to(recipient, 10, category: :peer_payment, from: [expiring, evergreen], **policy)
        assert_equal [[evergreen.id, 10]], allocations(transfer.outbound_transaction), "#{policy.inspect}: only the live source funds it"
        assert_equal 10, transfer.inbound_transactions.sum(:amount)
      end
    end

    assert_equal 100, expiring.reload.remaining_amount
    assert_equal 40, recipient.balance
  end

  test "a targeted transfer is funded like a targeted debit, and a refusal writes no transfer" do
    sender = points_wallet
    credit = sender.credit(100, category: :top_up)
    sender.reserve(100, category: :booking)
    recipient = create_wallet(users(:peer_user), asset_code: :points)

    error = assert_no_difference -> { Wallets::Transfer.count } do
      assert_raises(Wallets::InsufficientBalance) { sender.transfer_to(recipient, 10, category: :peer_payment, from: credit) }
    end
    assert_equal "Insufficient balance (0 < 10; 100 reserved)", error.message

    Wallets.configuration.allow_negative_balance = true
    assert_no_difference -> { Wallets::Transfer.count } do
      error = assert_raises(Wallets::InsufficientBalance) { sender.transfer_to(recipient, 101, category: :peer_payment, from: credit) }
      assert_equal "Insufficient balance (100 < 101 in the named credits; 100 reserved)", error.message
    end

    transfer = sender.transfer_to(recipient, 100, category: :peer_payment, from: credit)
    assert_equal "preserve", transfer.expiration_policy
    assert_equal [-100, 100, 0], balances(sender)
  end

  test "a targeted transfer refuses malformed sources before anything is written" do
    sender = points_wallet
    credit = sender.credit(100, category: :top_up)
    recipient = create_wallet(users(:peer_user), asset_code: :points)

    [nil, [], [credit, credit], recipient.credit(5, category: :top_up)].each do |from|
      assert_no_changes -> { [Wallets::Transfer.count, Wallets::Transaction.count] } do
        assert_raises(ArgumentError) { sender.transfer_to(recipient, 1, category: :peer_payment, from: from) }
      end
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

  def assert_nothing_written(wallet, &block)
    assert_no_changes(-> { [wallet.transactions.count, Wallets::Allocation.count, Wallets::Hold.where(wallet_id: wallet.id).count] }, &block)
  end
end
