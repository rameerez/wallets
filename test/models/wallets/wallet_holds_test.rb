# frozen_string_literal: true

require "test_helper"

# Holds and reservations as the wallet's balance math sees them: available,
# held and total balance, FEFO eligibility, signed availability, and how a
# wallet's holds go when the wallet does. Hold rows are written directly, so
# the math is pinned beneath the commands (WalletHoldCommandsTest).
class Wallets::WalletHoldsTest < ActiveSupport::TestCase
  # A ledger that opted in with a hold class whose table does not exist.
  class MissingTableHold < Wallets::HoldBase
    self.embedded_table_name = "wallets_holds_that_do_not_exist"
  end

  class MissingTableWallet < Wallets::Wallet
    self.hold_class_name = "Wallets::WalletHoldsTest::MissingTableHold"
  end

  setup do
    @owner = users(:new_user)
  end

  # ───────────────────────────────────────────────────────────────────────────
  # The capability switch
  # ───────────────────────────────────────────────────────────────────────────

  test "the standalone ledger keeps holds" do
    wallet = points_wallet

    assert Wallets::Wallet.holds_enabled?
    assert wallet.holds_enabled?
    assert_equal "Wallets::Hold", Wallets::Wallet.hold_class_name
    assert_equal Wallets::Hold, Wallets::Wallet.hold_class
  end

  test "WalletBase keeps no holds unless a ledger opts in, and says so loudly" do
    assert_nil Wallets::WalletBase.hold_class_name
    refute Wallets::WalletBase.holds_enabled?

    error = assert_raises(Wallets::HoldsNotEnabled) { Wallets::WalletBase.hold_class }
    assert_includes error.message, "Wallets::WalletBase does not keep holds"
    assert_operator Wallets::HoldsNotEnabled, :<, Wallets::Error
    assert_operator Wallets::InvalidHold, :<, Wallets::Error
  end

  test "an opted-in ledger whose holds table is missing fails loudly instead of ignoring holds" do
    wallet = points_wallet(100)

    assert_raises(ActiveRecord::StatementInvalid) do
      Wallets::Wallet.transaction(requires_new: true) { MissingTableWallet.find(wallet.id).balance }
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Readers
  # ───────────────────────────────────────────────────────────────────────────

  test "without holds every reader agrees with the balance it always had" do
    wallet = points_wallet(150)

    assert_equal 150, wallet.balance
    assert_equal 150, wallet.available_balance
    assert_equal 150, wallet.total_balance
    assert_equal 0, wallet.held_balance
    refute wallet.on_hold?
  end

  test "a credit hold moves the credit's value from available to held" do
    wallet = points_wallet
    held = wallet.credit(100, category: :reward)
    wallet.credit(50, category: :top_up)

    hold!(wallet, held)

    assert_equal 50, wallet.balance
    assert_equal 50, wallet.available_balance
    assert_equal 100, wallet.held_balance
    assert_equal 150, wallet.total_balance
    refute wallet.on_hold?, "a credit hold is not a hold on the wallet"
    refute wallet.has_enough_balance?(51)
    assert wallet.has_enough_balance?(50)
  end

  test "two reasons on one credit hold it once" do
    wallet = points_wallet
    held = wallet.credit(100, category: :reward)
    wallet.credit(50, category: :top_up)

    hold!(wallet, held, category: :fraud_review)
    hold!(wallet, held, category: :dispute)

    assert_equal 100, wallet.held_balance
    assert_equal 50, wallet.balance
    assert_equal 150, wallet.total_balance
  end

  test "releasing one reason keeps the credit held while another is active" do
    wallet = points_wallet
    held = wallet.credit(100, category: :reward)
    fraud = hold!(wallet, held, category: :fraud_review)
    dispute = hold!(wallet, held, category: :dispute)

    fraud.update!(released_at: Time.current, release_reason: "cleared")
    assert_equal 0, wallet.balance
    assert_equal 100, wallet.held_balance

    dispute.update!(released_at: Time.current, release_reason: "resolved")
    assert_equal 100, wallet.balance
    assert_equal 0, wallet.held_balance
  end

  test "only a credit's remaining value is held" do
    wallet = points_wallet
    held = wallet.credit(100, category: :reward)
    wallet.debit(30, category: :purchase)

    hold!(wallet, held)

    assert_equal 70, wallet.held_balance
    assert_equal 0, wallet.balance
    assert_equal 70, wallet.total_balance
  end

  test "a wallet hold covers every credit, including credits received later" do
    wallet = points_wallet(100)
    hold!(wallet)

    assert wallet.on_hold?
    assert_equal 0, wallet.balance
    assert_equal 100, wallet.held_balance

    later = wallet.credit(40, category: :reward)

    assert_equal 0, wallet.balance
    assert_equal 140, wallet.held_balance
    assert_equal 140, wallet.total_balance
    assert later.held?
  end

  test "a wallet hold puts even an empty wallet on hold" do
    wallet = points_wallet
    hold!(wallet)

    assert wallet.on_hold?
    assert_equal 0, wallet.balance
    assert_equal 0, wallet.held_balance
  end

  test "on_hold? means a hold on the whole wallet, not a credit hold or a reservation" do
    wallet = points_wallet
    credit = wallet.credit(100, category: :reward)
    hold!(wallet, credit)
    reservation!(wallet, 10)

    refute wallet.on_hold?
  end

  test "a credit held by its own reason and by a wallet hold counts once" do
    wallet = points_wallet
    credit = wallet.credit(100, category: :reward)
    hold!(wallet, credit)
    hold!(wallet)

    assert_equal 100, wallet.held_balance
    assert_equal 0, wallet.balance
    assert_equal 100, wallet.total_balance
  end

  test "released and lapsed wallet holds cover nothing" do
    freeze_time
    wallet = points_wallet(100)
    hold!(wallet, released_at: 1.minute.ago, release_reason: "cleared")
    hold!(wallet, releases_at: 1.minute.ago)

    refute wallet.on_hold?
    assert_equal 100, wallet.balance
    assert_equal 0, wallet.held_balance
  end

  test "a hold stops counting exactly at its deadline" do
    freeze_time
    wallet = points_wallet
    credit = wallet.credit(100, category: :reward)
    deadline = 3.days.from_now
    hold!(wallet, credit, releases_at: deadline)
    reservation!(wallet, 20, releases_at: deadline)
    hold!(wallet, releases_at: deadline)

    travel_to(deadline - 1.second) do
      assert_equal(-20, wallet.balance)
      assert_equal 120, wallet.held_balance
      assert wallet.on_hold?
      assert credit.held?
    end

    travel_to(deadline) do
      assert_equal 100, wallet.balance
      assert_equal 0, wallet.held_balance
      refute wallet.on_hold?
      refute credit.held?
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Transaction readers
  # ───────────────────────────────────────────────────────────────────────────

  test "a credit reports what is held and what is still available" do
    wallet = points_wallet
    free = wallet.credit(50, category: :top_up)
    held = wallet.credit(100, category: :reward)
    hold!(wallet, held)

    assert_equal [0, 50, false], readers(free)
    assert_equal [100, 0, true], readers(held)
  end

  test "a partly spent held credit holds its remainder, and a spent one holds nothing" do
    wallet = points_wallet
    first = wallet.credit(30, category: :top_up)
    second = wallet.credit(100, category: :reward)
    wallet.debit(50, category: :purchase)
    hold!(wallet, first)
    hold!(wallet, second)

    assert_equal [0, 0, false], readers(first), "fully spent: nothing left to hold"
    assert_equal [80, 0, true], readers(second)
  end

  test "debits hold nothing and fund nothing" do
    wallet = points_wallet(100)
    debit = wallet.debit(10, category: :purchase)
    hold!(wallet)

    assert_equal [0, 0, false], readers(debit)
  end

  test "an unsaved credit is not held, so no hold query runs for it" do
    wallet = points_wallet
    hold!(wallet)
    unsaved = wallet.transactions.build(amount: 10, category: :reward)

    statements = capture_sql { assert_equal [0, 10, false], readers(unsaved) }

    assert statements.none? { |sql| sql.match?(/wallets_holds/i) }
  end

  test "credits under a wallet hold read as held" do
    wallet = points_wallet
    credit = wallet.credit(100, category: :reward)
    hold!(wallet)

    assert_equal [100, 0, true], readers(credit)
  end

  test "credit readers evaluate at a given instant" do
    freeze_time
    wallet = points_wallet
    credit = wallet.credit(100, category: :reward)
    hold!(wallet, credit, releases_at: 1.day.from_now)

    assert_equal 100, credit.held_amount(at: 12.hours.from_now)
    assert_equal 0, credit.held_amount(at: 1.day.from_now)
    assert_equal 100, credit.available_amount(at: 1.day.from_now)
    refute credit.held?(at: 1.day.from_now)
  end

  test "reservations are an amount of the wallet, never a claim on one credit" do
    wallet = points_wallet
    credit = wallet.credit(100, category: :reward)
    reservation!(wallet, 80)

    assert_equal [0, 100, false], readers(credit)
    assert_equal 20, wallet.balance
  end

  test "expiry under a hold zeroes what is held and keeps the reasons" do
    wallet = points_wallet
    credit = wallet.credit(100, category: :reward, expires_at: 1.day.from_now)
    hold = hold!(wallet, credit, category: :fraud_review)

    travel 2.days do
      assert_equal [0, 0, false], readers(credit)
      assert_equal 0, wallet.held_balance
      assert_equal 0, wallet.total_balance
      assert_equal [hold], credit.holds.active.to_a, "the reason stays readable after expiry"
    end
  end

  test "expired credits fund nothing, held or not" do
    wallet = points_wallet
    covered = wallet.credit(100, category: :reward, expires_at: 1.day.from_now)
    uncovered = wallet.credit(50, category: :reward, expires_at: 1.day.from_now)
    hold!(wallet, covered)

    travel 2.days do
      assert_equal 0, covered.available_amount
      assert_equal 0, uncovered.available_amount
      assert covered.expired?
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Reservations
  # ───────────────────────────────────────────────────────────────────────────

  test "reservations add up, like pending card charges" do
    wallet = points_wallet(100)
    reservation!(wallet, 40)
    reservation!(wallet, 40)

    assert_equal 20, wallet.balance
    assert_equal 80, wallet.held_balance
    assert_equal 100, wallet.total_balance
    refute wallet.on_hold?
  end

  test "released and lapsed reservations reserve nothing" do
    freeze_time
    wallet = points_wallet(100)
    reservation!(wallet, 40, released_at: 1.minute.ago, release_reason: "cancelled")
    reservation!(wallet, 30, releases_at: 1.minute.ago)

    assert_equal 100, wallet.balance
    assert_equal 0, wallet.held_balance
  end

  test "debits stay within what reservations leave available" do
    wallet = points_wallet(100)
    reservation!(wallet, 80)

    assert_raises(Wallets::InsufficientBalance) { wallet.debit(30, category: :purchase) }

    wallet.debit(20, category: :purchase)
    assert_equal 0, wallet.balance
    assert_equal 80, wallet.total_balance
  end

  test "a reservation pins no bucket: debits still consume the soonest-expiring credit" do
    wallet = points_wallet
    expiring = wallet.credit(100, category: :reward, expires_at: 5.days.from_now)
    evergreen = wallet.credit(100, category: :top_up)
    reservation!(wallet, 150)

    spend = wallet.debit(30, category: :purchase)

    assert_equal [[expiring.id, 30]], spend.outgoing_allocations.pluck(:source_transaction_id, :amount)
    assert_equal 100, evergreen.reload.remaining_amount
    assert_equal 20, wallet.balance
  end

  test "with overdrafts on, spending reserved value is backed by buckets, not debt" do
    # Insufficient availability and insufficient buckets are different
    # conditions: the reservation is left underfunded, yet nothing is unbacked.
    Wallets.configuration.allow_negative_balance = true
    wallet = points_wallet
    credit = wallet.credit(100, category: :reward)
    reservation!(wallet, 80)

    spend = wallet.debit(50, category: :purchase)

    assert_equal 0, spend.unbacked_amount
    assert_equal 50, credit.reload.remaining_amount
    assert_equal(-30, wallet.balance)
    assert_equal 80, wallet.held_balance
    assert_equal 50, wallet.total_balance
  end

  # ───────────────────────────────────────────────────────────────────────────
  # The balance identity
  # ───────────────────────────────────────────────────────────────────────────

  test "total balance is always available plus held" do
    Wallets.configuration.allow_negative_balance = true
    wallet = points_wallet
    held = wallet.credit(100, category: :reward)
    wallet.credit(60, category: :top_up, expires_at: 10.days.from_now)
    wallet.debit(20, category: :purchase)

    snapshots = []
    snapshots << snapshot(wallet)
    hold!(wallet, held)
    snapshots << snapshot(wallet)
    reservation!(wallet, 30)
    snapshots << snapshot(wallet)
    wallet.debit(50, category: :purchase)
    snapshots << snapshot(wallet)
    hold!(wallet)
    snapshots << snapshot(wallet)
    travel(11.days) { snapshots << snapshot(wallet) }

    snapshots.each do |available, held_value, total, ledger_total|
      assert_equal total, available + held_value
      assert_equal ledger_total, total, "total balance is P - N"
    end
  end

  test "each balance reader is one statement, so all its terms share one snapshot" do
    # Separate statements would each see their own snapshot under read
    # committed: a covered credit committed between two of them could count
    # in P and miss C.
    wallet = points_wallet
    held = wallet.credit(100, category: :reward)
    wallet.credit(50, category: :top_up)
    wallet.debit(10, category: :purchase)
    hold!(wallet, held)
    reservation!(wallet, 20)

    {balance: 30, available_balance: 30, held_balance: 110, total_balance: 140}.each do |reader, expected|
      value = nil
      statements = capture_sql { value = wallet.public_send(reader) }

      assert_equal expected, value, reader
      assert_equal 1, statements.size, "#{reader} must be one statement:\n#{statements.join("\n")}"
      assert_match(/wallets_holds/, statements.sole, "#{reader} reads the reservations in the same statement")
    end
  end

  test "available, held and total come from one set of components" do
    Wallets.configuration.allow_negative_balance = true
    wallet = points_wallet
    held = wallet.credit(100, category: :reward)
    wallet.credit(50, category: :top_up, expires_at: 1.day.from_now)
    wallet.debit(200, category: :purchase)
    wallet.credit(30, category: :reward)
    hold!(wallet, held)
    reservation!(wallet, 20)

    components = wallet.send(:balance_components)

    assert_equal [30, 0, 20, 50], components.to_a, "P, C, R, N: the held credit was spent before its hold"
    assert_equal components.total, components.available + components.held
    assert_equal [components.available, components.held, components.total], [wallet.balance, wallet.held_balance, wallet.total_balance]
  end

  test "held balance can exceed total balance when coverage meets reservations" do
    wallet = points_wallet(100)
    reservation!(wallet, 80)
    hold!(wallet)

    assert_equal 180, wallet.held_balance
    assert_equal 100, wallet.total_balance
    assert_equal(-80, wallet.balance)
  end

  test "held balance can exceed total balance once reserved value expires" do
    wallet = points_wallet
    wallet.credit(100, category: :reward, expires_at: 1.day.from_now)
    reservation!(wallet, 100)

    travel 2.days do
      assert_equal 0, wallet.total_balance
      assert_equal 100, wallet.held_balance
      assert_equal(-100, wallet.balance)
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Signed availability (D6)
  # ───────────────────────────────────────────────────────────────────────────

  test "available balance can go negative with overdrafts off, and the wallet stays saveable" do
    wallet = points_wallet
    credit = wallet.credit(100, category: :reward)
    reservation!(wallet, 80)
    hold!(wallet, credit)
    assert_equal(-80, wallet.balance)

    incoming = wallet.credit(10, category: :top_up)

    assert_equal(-80, incoming.balance_before)
    assert_equal(-70, incoming.balance_after)
    assert_equal(-70, wallet.reload.read_attribute(:balance), "the cache stores the signed available balance")
    assert wallet.valid?
    assert_raises(Wallets::InsufficientBalance) { wallet.debit(1, category: :purchase) }
  end

  test "expiry can take available balance below zero and the wallet stays saveable" do
    wallet = points_wallet
    wallet.credit(100, category: :reward, expires_at: 1.day.from_now)
    reservation!(wallet, 100)

    travel 2.days do
      assert_equal(-100, wallet.balance)

      wallet.credit(30, category: :top_up)

      assert_equal(-70, wallet.reload.balance)
      assert_equal(-70, wallet.read_attribute(:balance))
    end
  end

  test "the cached balance and the snapshots record the available balance" do
    wallet = points_wallet
    held = wallet.credit(100, category: :reward)
    hold!(wallet, held)

    credit = wallet.credit(40, category: :top_up)

    assert_equal 0, credit.balance_before
    assert_equal 40, credit.balance_after
    assert_equal 40, wallet.reload.read_attribute(:balance)
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Eligibility: what a debit may consume
  # ───────────────────────────────────────────────────────────────────────────

  test "FEFO skips held credits" do
    wallet = points_wallet
    expiring_but_held = wallet.credit(100, category: :reward, expires_at: 2.days.from_now)
    evergreen = wallet.credit(100, category: :top_up)
    hold!(wallet, expiring_but_held)

    spend = wallet.debit(30, category: :purchase)

    assert_equal [[evergreen.id, 30]], spend.outgoing_allocations.pluck(:source_transaction_id, :amount)
    assert_equal 100, expiring_but_held.reload.remaining_amount
    assert_equal 70, wallet.balance
    assert_equal 100, wallet.held_balance
  end

  test "a debit cannot consume a held credit" do
    wallet = points_wallet
    held = wallet.credit(100, category: :reward)
    hold!(wallet, held)

    assert_no_difference -> { wallet.transactions.count } do
      assert_raises(Wallets::InsufficientBalance) { wallet.debit(10, category: :purchase) }
    end
    assert_equal 100, held.reload.remaining_amount
  end

  test "with overdrafts on, a debit goes unbacked rather than touch held value" do
    Wallets.configuration.allow_negative_balance = true
    wallet = points_wallet
    held = wallet.credit(100, category: :reward)
    hold!(wallet, held)

    spend = wallet.debit(40, category: :purchase)

    assert_empty spend.outgoing_allocations
    assert_equal 40, spend.unbacked_amount
    assert_equal 100, held.reload.remaining_amount
    assert_equal(-40, wallet.balance)
    assert_equal 100, wallet.held_balance
    assert_equal 60, wallet.total_balance
  end

  test "with overdrafts on, a debit drains eligible credits before going unbacked" do
    Wallets.configuration.allow_negative_balance = true
    wallet = points_wallet
    held = wallet.credit(100, category: :reward)
    free = wallet.credit(30, category: :top_up)
    hold!(wallet, held)

    spend = wallet.debit(50, category: :purchase)

    assert_equal [[free.id, 30]], spend.outgoing_allocations.pluck(:source_transaction_id, :amount)
    assert_equal 20, spend.unbacked_amount
    assert_equal 100, held.reload.remaining_amount
  end

  test "a wallet hold leaves no credit eligible" do
    Wallets.configuration.allow_negative_balance = true
    wallet = points_wallet(100)
    hold!(wallet)

    spend = wallet.debit(10, category: :purchase)

    assert_empty spend.outgoing_allocations
    assert_equal 10, spend.unbacked_amount
  end

  test "insufficient_balance names what holds and reservations keep out of reach" do
    events = []
    Wallets.configuration.on_insufficient_balance { |context| events << context }
    wallet = points_wallet
    held = wallet.credit(100, category: :reward)
    wallet.credit(50, category: :top_up)
    hold!(wallet, held)
    reservation!(wallet, 30)

    error = assert_raises(Wallets::InsufficientBalance) { wallet.debit(40, category: :purchase, metadata: {order: "o-1"}) }

    assert_equal "Insufficient balance (20 < 40; 100 held, 30 reserved)", error.message
    metadata = events.sole.metadata
    assert_equal 20, metadata[:available]
    assert_equal 40, metadata[:required]
    assert_equal 100, metadata[:held]
    assert_equal 30, metadata[:reserved]
    assert_equal "o-1", metadata[:order]
    assert_equal wallet.total_balance, metadata[:available] + metadata[:held] + metadata[:reserved]
    assert_equal 20, events.sole.previous_balance
    assert_equal 20, events.sole.new_balance
  end

  test "the insufficient balance message names only what is non-zero" do
    wallet = points_wallet(20)
    reservation!(wallet, 10)

    error = assert_raises(Wallets::InsufficientBalance) { wallet.debit(15, category: :purchase) }
    assert_equal "Insufficient balance (10 < 15; 10 reserved)", error.message

    other = create_wallet(users(:peer_user), asset_code: :points, initial_balance: 5)
    error = assert_raises(Wallets::InsufficientBalance) { other.debit(10, category: :purchase) }
    assert_equal "Insufficient balance (5 < 10)", error.message, "unchanged when nothing is held"
  end

  test "insufficient_balance reports zero held and reserved when nothing is" do
    events = []
    Wallets.configuration.on_insufficient_balance { |context| events << context }
    wallet = points_wallet(5)

    assert_raises(Wallets::InsufficientBalance) { wallet.debit(10, category: :purchase) }

    assert_equal 0, events.sole.metadata[:held]
    assert_equal 0, events.sole.metadata[:reserved]
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Transfers
  # ───────────────────────────────────────────────────────────────────────────

  test "held value never leaves through a transfer" do
    events = []
    Wallets.configuration.on_insufficient_balance { |context| events << context }
    sender = points_wallet
    held = sender.credit(100, category: :reward)
    hold!(sender, held)
    recipient = create_wallet(users(:peer_user), asset_code: :points)

    error = assert_no_difference -> { Wallets::Transfer.count } do
      assert_raises(Wallets::InsufficientBalance) { sender.transfer_to(recipient, 10, category: :peer_payment) }
    end

    assert_equal "Insufficient balance (0 < 10; 100 held)", error.message
    assert_equal 100, events.sole.metadata[:held]
    assert_equal 0, events.sole.metadata[:reserved]
  end

  test "a fully backed transfer at zero available keeps its source expirations" do
    # A reservation leaves nothing available, but overdrafts are on and FEFO
    # backs every unit from the credit, so there is an expiration to keep.
    Wallets.configuration.allow_negative_balance = true
    sender = points_wallet
    expiration = 30.days.from_now
    sender.credit(100, category: :reward, expires_at: expiration)
    reservation!(sender, 100)
    recipient = create_wallet(users(:peer_user), asset_code: :points)

    transfer = sender.transfer_to(recipient, 40, category: :peer_payment)

    assert_equal "preserve", transfer.expiration_policy
    assert_equal 0, transfer.outbound_transaction.unbacked_amount
    assert_equal expiration.to_i, transfer.inbound_transactions.sole.expires_at.to_i
    assert_equal(-40, sender.balance)
    assert_equal 40, recipient.balance
  end

  test "earlier debt no longer collapses a fully backed transfer to evergreen" do
    # The behavior change of 0.4 without any hold: old debt, then fresh
    # credits, then a transfer above the net available balance that FEFO
    # still backs in full. 0.2 and 0.3 judged it by `amount > balance` and
    # dropped the source expiration; it now keeps it.
    Wallets.configuration.allow_negative_balance = true
    sender = points_wallet
    sender.debit(50, category: :purchase)
    expiration = 20.days.from_now
    sender.credit(80, category: :reward, expires_at: expiration)
    recipient = create_wallet(users(:peer_user), asset_code: :points)
    assert_equal 30, sender.balance

    transfer = sender.transfer_to(recipient, 60, category: :peer_payment)

    assert_equal "preserve", transfer.expiration_policy
    assert_equal 0, transfer.outbound_transaction.unbacked_amount
    inbound = transfer.inbound_transactions.sole
    assert_equal 60, inbound.amount
    assert_equal expiration.to_i, inbound.expires_at.to_i
    assert_equal(-30, sender.balance)
    assert_equal 60, recipient.balance
  end

  test "a transfer with an actual unbacked portion still collapses to evergreen" do
    Wallets.configuration.allow_negative_balance = true
    sender = points_wallet
    held = sender.credit(100, category: :reward)
    sender.credit(30, category: :top_up, expires_at: 10.days.from_now)
    hold!(sender, held)
    recipient = create_wallet(users(:peer_user), asset_code: :points)

    transfer = sender.transfer_to(recipient, 50, category: :peer_payment)

    assert_equal "none", transfer.expiration_policy
    assert_equal 20, transfer.outbound_transaction.unbacked_amount
    assert_equal "none", transfer.outbound_transaction.metadata["transfer_expiration_policy"]
    inbound = transfer.inbound_transactions.sole
    assert_equal 50, inbound.amount
    assert_nil inbound.expires_at
    assert_equal 100, held.reload.remaining_amount, "the held credit funds nothing"
  end

  # ───────────────────────────────────────────────────────────────────────────
  # One evaluation instant per mutation
  # ───────────────────────────────────────────────────────────────────────────

  test "a debit reads its whole ledger at the one instant it sampled under the lock" do
    # The clock jumps past the credit's expiry right after the debit samples
    # its instant. Reading the clock again for allocation would see no live
    # bucket and refuse the debit its own affordability check accepted.
    travel_to Time.utc(2030, 1, 1, 12)
    wallet = points_wallet
    credit = wallet.credit(100, category: :reward, expires_at: 1.second.from_now)
    sampled = Time.current
    Time.stubs(:current).returns(sampled).then.returns(sampled + 1.minute)

    spend = wallet.debit(60, category: :purchase)

    assert_equal [[credit.id, 60]], spend.outgoing_allocations.pluck(:source_transaction_id, :amount)
    assert_equal 100, spend.balance_before
    assert_equal 40, spend.balance_after
  end

  test "a transfer evaluates both wallets at the same instant" do
    travel_to Time.utc(2030, 1, 1, 12)
    sender = points_wallet
    credit = sender.credit(100, category: :reward, expires_at: 1.second.from_now)
    recipient = create_wallet(users(:peer_user), asset_code: :points)
    sampled = Time.current
    Time.stubs(:current).returns(sampled).then.returns(sampled + 1.minute)

    transfer = sender.transfer_to(recipient, 60, category: :peer_payment)

    assert_equal "preserve", transfer.expiration_policy
    assert_equal [[credit.id, 60]], transfer.outbound_transaction.outgoing_allocations.pluck(:source_transaction_id, :amount)
    inbound = transfer.inbound_transactions.sole
    assert_equal credit.expires_at.to_i, inbound.expires_at.to_i
    assert_equal 0, inbound.balance_before
    assert_equal 60, inbound.balance_after, "the recipient's credit is live at the transfer's instant"
  end

  test "the pinned instant is released after the mutation, even when it fails" do
    wallet = points_wallet(10)

    assert_raises(Wallets::InsufficientBalance) { wallet.debit(50, category: :purchase) }

    assert_nil wallet.instance_variable_get(:@evaluation_time)
    refute wallet.send(:current_reads?)
    travel 1.day do
      assert_equal Time.current, wallet.send(:evaluation_time)
    end
  end

  test "every command bumps the wallet row, even when the available balance does not move" do
    # A credit straight under a wallet hold leaves the available balance
    # where it was. The row must change anyway: it is how a stale snapshot is
    # told from a current one.
    wallet = points_wallet(100)
    hold!(wallet)
    wallet.credit(1, category: :reward)
    before = wallet.reload.updated_at

    travel 1.second do
      wallet.credit(10, category: :reward)
    end

    assert_equal 0, wallet.reload.balance
    assert_operator wallet.updated_at, :>, before
  end

  test "a command that moves no balance writes the wallet row even under no_touching" do
    wallet = points_wallet(100)
    hold!(wallet)
    before = wallet.reload.updated_at

    travel 1.second do
      Wallets::Wallet.no_touching { wallet.credit(10, category: :reward) }
    end

    assert_operator wallet.reload.updated_at, :>, before
    assert_equal 0, wallet.read_attribute(:balance)
  end

  test "two commands in one microsecond still leave two different rows behind" do
    # A frozen clock stands in for two commits within one microsecond: the
    # second marker steps past the first instead of repeating it.
    freeze_time
    wallet = points_wallet(100)
    markers = [wallet.reload.updated_at]

    wallet.debit(10, category: :purchase)               # the balance moves: save!
    markers << wallet.reload.updated_at
    hold!(wallet)
    wallet.credit(5, category: :reward)                 # it does not: the marker alone
    markers << wallet.reload.updated_at
    wallet.credit(5, category: :reward)
    markers << wallet.reload.updated_at

    assert_equal markers.sort, markers
    assert_equal markers.uniq, markers, "every command leaves a later marker"
    assert_equal Rational(1, 1_000_000), markers.last - markers[-2]
  end

  test "a stale snapshot is detected against the locked row and remembered past its savepoint" do
    # The interleavings themselves run on MySQL in CurrentReadsTest, and the
    # end of the verdict in StaleSnapshotTest; this pins the detection on
    # every adapter.
    wallet = points_wallet(100)
    Wallets::Wallet.stubs(:current_reads_need_locks?).returns(true)

    Wallets::Wallet.transaction(requires_new: true) do
      wallet.lock!
      refute wallet.send(:stale_snapshot?), "the snapshot shows the very row the lock returned"

      wallet.updated_at += 1.second # the lock returned a row the snapshot has not seen
      assert wallet.send(:stale_snapshot?)

      wallet.restore_attributes
      assert wallet.send(:stale_snapshot?), "still stale once the rows match again (as after its own write)"

      raise ActiveRecord::Rollback
    end

    assert wallet.reload.send(:stale_snapshot?), "a savepoint ending is not the real transaction ending"
  end

  test "stale snapshots are never suspected where plain reads are always current" do
    wallet = points_wallet(100)
    Wallets::Wallet.stubs(:current_reads_need_locks?).returns(false)
    wallet.updated_at += 1.second

    refute wallet.send(:stale_snapshot?)
  ensure
    wallet&.restore_attributes
  end

  test "the read builders lock exactly when asked to on a database that needs it" do
    wallet = points_wallet(100)
    relation = wallet.transactions.credits

    Wallets::Wallet.stubs(:current_reads_need_locks?).returns(true)
    assert_equal "FOR UPDATE", wallet.send(:current_read, relation, true).lock_value
    assert_nil wallet.send(:current_read, relation, false).lock_value
    assert_equal " FOR UPDATE", wallet.send(:locking_clause, true)
    assert_equal "", wallet.send(:locking_clause, false)
    assert_match(/FOR UPDATE\)\z/, wallet.send(:remaining_amount_sql, lock: true))
    locked_coverage = Wallets::Wallet.coverage_sql(at: Time.current, lock: true)
    unless Wallets::Wallet.connection.adapter_name.match?(/sqlite/i) # SQLite's SQL has no row locks to print
      assert_equal 2, locked_coverage.scan("FOR UPDATE").size
    end

    Wallets::Wallet.stubs(:current_reads_need_locks?).returns(false)
    assert_nil wallet.send(:current_read, relation, true).lock_value
    assert_equal "", wallet.send(:locking_clause, true)
    refute_includes Wallets::Wallet.coverage_sql(at: Time.current, lock: true), "FOR UPDATE"
  end

  test "only MySQL-family adapters answer plain reads from a stale snapshot" do
    expected = Wallets::Wallet.connection.adapter_name.match?(/mysql|trilogy/i)

    assert_equal expected, Wallets::Wallet.current_reads_need_locks?
  end

  test "a nested pin keeps its caller's instant" do
    wallet = points_wallet
    outer = 1.day.ago

    inner = wallet.send(:evaluating_at, outer, current_reads: true) do
      wallet.send(:evaluating_at, Time.current) { [wallet.send(:evaluation_time), wallet.send(:current_reads?)] }
    end

    assert_equal [outer, true], inner
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Destroying wallets, credits and owners
  # ───────────────────────────────────────────────────────────────────────────

  test "destroying a wallet destroys its holds before its transactions" do
    wallet, credit, debit = wallet_with_every_kind_of_hold
    hold_ids = wallet.holds.pluck(:id)
    assert_equal 4, hold_ids.size

    statements = capture_sql { wallet.destroy! }

    assert_empty Wallets::Hold.where(id: hold_ids)
    assert_empty Wallets::Transaction.where(id: [credit.id, debit.id])
    first_hold_delete = statements.index { |sql| sql.match?(/\ADELETE FROM .?wallets_holds/i) }
    first_transaction_delete = statements.index { |sql| sql.match?(/\ADELETE FROM .?wallets_transactions/i) }
    assert first_hold_delete, "holds must be deleted"
    assert_operator first_hold_delete, :<, first_transaction_delete, "holds go before the transactions they reference"
  end

  test "a capture-linked reservation is destroyed with its wallet, never nullified" do
    wallet, _credit, debit = wallet_with_every_kind_of_hold
    captured = debit.captured_reservation

    statements = capture_sql { wallet.destroy! }

    refute Wallets::Hold.exists?(captured.id)
    assert statements.none? { |sql| sql.match?(/\AUPDATE .?wallets_holds/i) }, "no hold row may be updated on the way out"
  end

  test "a capture debit cannot be destroyed out from under its reservation" do
    _wallet, _credit, debit = wallet_with_every_kind_of_hold
    captured = debit.captured_reservation

    assert_raises(ActiveRecord::InvalidForeignKey) do
      Wallets::Transaction.transaction(requires_new: true) { debit.destroy }
    end

    assert_equal debit.id, captured.reload.capture_transaction_id
  end

  test "destroying a credit destroys the reasons that hold it" do
    wallet = points_wallet
    credit = wallet.credit(100, category: :reward)
    reasons = [hold!(wallet, credit, category: :fraud_review), hold!(wallet, credit, category: :dispute)]
    wallet_hold = hold!(wallet)

    credit.destroy!

    assert_empty Wallets::Hold.where(id: reasons.map(&:id))
    assert Wallets::Hold.exists?(wallet_hold.id), "holds on the wallet are not the credit's"
  end

  test "a hold that refuses to go aborts its wallet's destruction" do
    wallet, credit, _debit = wallet_with_every_kind_of_hold
    hold_ids = wallet.holds.pluck(:id)
    # The other holds really are destroyed first; the last one refuses.
    refusing = wallet.holds.load.last
    refusing.stubs(:destroy!).raises(ActiveRecord::RecordNotDestroyed.new("refused", refusing))

    refute wallet.destroy, "destroy reports the refusal, as for any dependent destroy"

    assert Wallets::Wallet.exists?(wallet.id)
    assert Wallets::Transaction.exists?(credit.id)
    assert_equal hold_ids.sort, Wallets::Hold.where(wallet_id: wallet.id).pluck(:id).sort, "holds destroyed before the refusal come back"

    reloaded = Wallets::Wallet.find(wallet.id)
    reloaded.holds.load.first.stubs(:destroy!).raises(ActiveRecord::RecordNotDestroyed.new("refused"))
    assert_raises(ActiveRecord::RecordNotDestroyed) { reloaded.destroy! }
    assert Wallets::Wallet.exists?(wallet.id)
  end

  test "destroying an owner takes their wallets' holds with them" do
    owner = User.create!(email: "holds-cascade-#{SecureRandom.hex(4)}@example.com", name: "Cascade")
    wallet = owner.wallet(:coins)
    credit = wallet.credit(100, category: :reward)
    hold!(wallet, credit)
    reservation!(wallet, 10)

    owner.destroy!

    assert_empty Wallets::Hold.where(wallet_id: wallet.id)
    assert_empty Wallets::Wallet.where(id: wallet.id)
  end

  private

  def points_wallet(initial_balance = 0)
    create_wallet(@owner, asset_code: :points, initial_balance: initial_balance)
  end

  def readers(transaction)
    [transaction.held_amount, transaction.available_amount, transaction.held?]
  end

  def snapshot(wallet)
    ledger_total = wallet.send(:positive_remaining_balance) - wallet.send(:unbacked_negative_balance)
    [wallet.balance, wallet.held_balance, wallet.total_balance, ledger_total]
  end

  # A credit hold, a wallet hold, an open reservation, and a reservation
  # captured into a debit: every row shape that references the wallet's
  # transactions.
  def wallet_with_every_kind_of_hold
    wallet = points_wallet
    credit = wallet.credit(100, category: :reward)
    wallet.credit(100, category: :top_up)
    debit = wallet.debit(40, category: :purchase)
    hold!(wallet, credit)
    hold!(wallet, releases_at: 1.day.from_now)
    reservation!(wallet, 10)
    reservation!(wallet, 40, released_at: Time.current, release_reason: "captured", capture_transaction: debit)

    [wallet, credit, debit]
  end
end
