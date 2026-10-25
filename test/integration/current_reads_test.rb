# frozen_string_literal: true

require "test_helper"

# A wallet command may run inside a caller's transaction that has already
# read something. Under MySQL's default repeatable read that first read fixes
# the transaction's snapshot, and taking the wallet lock afterwards does not
# refresh it: a mutation that finds its snapshot stale must read current rows.
# These tests interleave real connections, always through the real commands,
# to prove it, and prove the converse too: commands whose snapshot is current
# take no extra locks, because extra InnoDB gap locks deadlock unrelated
# wallets. The hold commands race here too: against debits on the same
# credit, and against each other on one hold. So do plain debits and
# transfers, to prove the row locks serialize them without deadlocks.
# PostgreSQL reads current rows per statement and runs every test as well.
# SQLite serializes writers for the whole database, so none of these
# interleavings can exist there.
#
# Every racer runs on a connection of its own, and every wait is bounded: a
# race that goes wrong fails its test with the error that ended it, never
# hangs the suite, and leaves no transaction or connection behind.
class CurrentReadsTest < ActiveSupport::TestCase
  # Real connections must see each other's commits: transactional tests
  # would pin one shared connection to every thread.
  self.use_transactional_tests = false

  # How long any one step of a race may take before the test gives up on
  # it: far longer than any real step, far shorter than a hung suite.
  PATIENCE = 10 # seconds

  setup do
    skip "SQLite serializes writers: no transaction can read, wait, then write" if sqlite?

    @owners = []
    @wallet = new_wallet(initial_balance: 100)
    @credit = @wallet.transactions.credits.sole
  end

  teardown do
    @owners&.each(&:destroy!)
  end

  # ───────────────────────────────────────────────────────────────────────────
  # A stale snapshot is detected and read past
  # ───────────────────────────────────────────────────────────────────────────

  test "a debit sees a reservation committed after its caller's first read" do
    outcome = after_a_stale_read(-> { Wallets::Wallet.find(@wallet.id).reserve(80, category: :booking) }) do |wallet|
      wallet.debit(60, category: :purchase)
    rescue Wallets::InsufficientBalance => error
      error
    end

    assert_kind_of Wallets::InsufficientBalance, outcome
    assert_equal "Insufficient balance (20 < 60; 80 reserved)", outcome.message
    assert_empty @wallet.transactions.debits
  end

  test "a debit never spends a credit that a hold committed after its caller's first read covers" do
    Wallets.configuration.allow_negative_balance = true

    spend = after_a_stale_read(-> { Wallets::Wallet.find(@wallet.id).hold(@credit, category: :fraud_review) }) do |wallet|
      wallet.debit(30, category: :purchase)
    end

    assert_empty spend.outgoing_allocations, "the covered credit is not eligible"
    assert_equal 30, spend.unbacked_amount
    assert_equal 100, @credit.reload.remaining_amount
  end

  test "a reservation sees a wallet hold committed after its caller's first read" do
    # Transaction A reads, B puts the wallet on hold and commits, then A takes
    # the wallet lock: what A may reserve is what is available now, nothing.
    outcome = after_a_stale_read(-> { Wallets::Wallet.find(@wallet.id).hold(category: :chargeback) }) do |wallet|
      wallet.reserve(50, category: :booking)
    rescue Wallets::InsufficientBalance => error
      error
    end

    assert_kind_of Wallets::InsufficientBalance, outcome
    assert_equal "Insufficient balance (0 < 50; 100 held)", outcome.message
    assert_empty Wallets::Hold.where(wallet_id: @wallet.id).reservations
  end

  test "hold refuses a credit that a debit committed after its caller's first read spent" do
    outcome = after_a_stale_read(-> { Wallets::Wallet.find(@wallet.id).debit(100, category: :purchase) }) do |wallet|
      wallet.hold(Wallets::Transaction.find(@credit.id), category: :fraud_review)
    rescue Wallets::InvalidHold => error
      error
    end

    assert_kind_of Wallets::InvalidHold, outcome
    assert_equal "Credit #{@credit.id} has no remaining value to hold", outcome.message
    assert_empty Wallets::Hold.where(wallet_id: @wallet.id)
  end

  test "allocation never spends what a debit committed after its caller's first read already took" do
    Wallets.configuration.allow_negative_balance = true

    spend = after_a_stale_read(-> { Wallets::Wallet.find(@wallet.id).debit(60, category: :purchase) }) do |wallet|
      wallet.debit(60, category: :purchase)
    end

    assert_equal [[@credit.id, 40]], spend.outgoing_allocations.pluck(:source_transaction_id, :amount)
    assert_equal 20, spend.unbacked_amount
    assert_equal 100, @credit.incoming_allocations.sum(:amount), "the credit is never over-allocated"
    assert_equal(-20, @wallet.reload.balance)
  end

  test "a caller's own write to the wallet row never passes a stale snapshot off as current" do
    # The caller's write makes the row it reads match the locked row, while
    # its ledger snapshot still misses the other debit.
    Wallets.configuration.allow_negative_balance = true

    [->(wallet) { wallet.touch }, ->(wallet) { wallet.update!(metadata: {note: "seen"}) }].each do |own_write|
      wallet = new_wallet(initial_balance: 100)
      credit = wallet.transactions.credits.sole

      spend = after_a_stale_read(-> { Wallets::Wallet.find(wallet.id).debit(60, category: :purchase) }, wallet: wallet) do |stale|
        own_write.call(stale)
        stale.debit(60, category: :purchase)
      end

      assert_equal 40, spend.outgoing_allocations.sum(:amount)
      assert_equal 100, credit.incoming_allocations.sum(:amount), "the credit is never over-allocated"
    end
  end

  test "a command that moves no balance still tells a later reader its snapshot is stale" do
    # With the clock frozen the second reason writes the wallet row at the
    # very instant the first one did; only a strictly increasing marker can
    # tell the two rows apart.
    freeze_time
    fraud = @wallet.hold(@credit, category: :fraud_review)
    released = Queue.new
    Wallets.configuration.on_hold_released { |context| released << context.new_balance }

    after_a_stale_read(-> { Wallets::Wallet.find(@wallet.id).hold(@credit, category: :dispute) }) do
      Wallets::Hold.find(fraud.id).release!
    end

    assert_equal [0], drain(released), "the dispute still holds the credit"
    assert_equal 0, @wallet.reload.read_attribute(:balance)
  end

  test "a touch back in time cannot hide a hold committed after the caller's first read" do
    # A snapshots the credit covered by its fraud hold. B adds a dispute over
    # the same value (the balance does not move) and touches the wallet back
    # to the updated_at A saw. Only the ledger revision still tells A that its
    # snapshot is stale: released, A's hold must leave the credit held.
    fraud = @wallet.hold(@credit, category: :fraud_review)
    seen_by_a = @wallet.reload.updated_at
    released = Queue.new
    Wallets.configuration.on_hold_released { |context| released << context.new_balance }

    dispute_and_hide_it = lambda do
      twin = Wallets::Wallet.find(@wallet.id)
      twin.hold(Wallets::Transaction.find(@credit.id), category: :dispute)
      twin.touch(time: seen_by_a)
      assert_equal seen_by_a, twin.reload.updated_at, "the touch restores what A saw"
    end

    outcome = after_a_stale_read(dispute_and_hide_it) do |stale|
      Wallets::Hold.find(fraud.id).release!
      stale.debit(10, category: :purchase)
    rescue Wallets::InsufficientBalance => error
      error
    end

    assert_equal [0], drain(released), "available reads 0: the dispute still holds the credit"
    assert_kind_of Wallets::InsufficientBalance, outcome, "the debit is refused"
    assert_empty @wallet.transactions.debits
    assert_equal 100, @credit.reload.remaining_amount
    assert_equal 0, @wallet.read_attribute(:balance)
  end

  test "a preserved transfer keeps the expiry of a credit committed after its caller's first read" do
    sender = new_wallet
    recipient = new_wallet
    expiration = 30.days.from_now.change(usec: 0)

    transfer = after_a_stale_read(-> { Wallets::Wallet.find(sender.id).credit(100, category: :reward, expires_at: expiration) }, wallet: sender) do |stale|
      stale.transfer_to(Wallets::Wallet.find(recipient.id), 60, category: :peer_payment)
    end

    assert_equal "preserve", transfer.expiration_policy
    assert_equal [[60, expiration]], transfer.inbound_transactions.map { |credit| [credit.amount, credit.expires_at] }
  end

  test "a transfer reads its recipient's ledger as it is now" do
    recipient = new_wallet(initial_balance: 100)

    transfer = after_a_stale_read(-> { Wallets::Wallet.find(recipient.id).debit(60, category: :purchase) }) do |stale|
      stale.transfer_to(Wallets::Wallet.find(recipient.id), 10, category: :peer_payment)
    end

    inbound = transfer.inbound_transactions.sole
    assert_equal [40, 50], [inbound.balance_before, inbound.balance_after]
    assert_equal 50, recipient.reload.read_attribute(:balance)
  end

  # ───────────────────────────────────────────────────────────────────────────
  # How long a stale verdict lasts
  # ───────────────────────────────────────────────────────────────────────────

  test "a stale snapshot stays stale for the rest of the transaction" do
    # After its first command the transaction has written the wallet row, so
    # its snapshot shows its own write; only the remembered verdict keeps the
    # second command reading current rows.
    Wallets.configuration.allow_negative_balance = true

    spends = after_a_stale_read(-> { Wallets::Wallet.find(@wallet.id).debit(60, category: :purchase) }) do |wallet|
      [wallet.debit(20, category: :purchase), Wallets::Wallet.find(@wallet.id).debit(30, category: :purchase)]
    end

    assert_equal [[@credit.id, 20]], spends.first.outgoing_allocations.pluck(:source_transaction_id, :amount)
    assert_equal [[@credit.id, 20]], spends.second.outgoing_allocations.pluck(:source_transaction_id, :amount)
    assert_equal 10, spends.second.unbacked_amount
    assert_equal 100, @credit.incoming_allocations.sum(:amount), "the credit is never over-allocated"
  end

  test "a stale snapshot stays stale for the rest of a non-joinable transaction" do
    # Under `transaction(joinable: false)` each command's savepoint runs its
    # own commit callbacks the moment it is released, while the real
    # transaction, and its snapshot, carry on.
    Wallets.configuration.allow_negative_balance = true

    spends = after_a_stale_read(-> { Wallets::Wallet.find(@wallet.id).debit(60, category: :purchase) }, joinable: false) do |wallet|
      [wallet.debit(20, category: :purchase), Wallets::Wallet.find(@wallet.id).debit(30, category: :purchase)]
    end

    assert_equal [20, 20], spends.map { |spend| spend.outgoing_allocations.sum(:amount) }
    assert_equal 100, @credit.incoming_allocations.sum(:amount), "the credit is never over-allocated"
  end

  test "the stale verdict outlives savepoints and ends with the real transaction" do
    skip "only MySQL answers plain reads from a stale snapshot" unless mysql?

    remembered = {}
    after_a_stale_read(-> { Wallets::Wallet.find(@wallet.id).debit(60, category: :purchase) }) do |wallet|
      assert_raises(Wallets::InsufficientBalance) { wallet.reserve(1_000, category: :booking) }
      remembered[:after_a_rolled_back_command] = remembered_stale_snapshots

      Wallets::Wallet.transaction(requires_new: true) { wallet.debit(5, category: :purchase) }
      remembered[:after_a_released_savepoint] = remembered_stale_snapshots

      Wallets::Wallet.transaction(requires_new: true) do
        wallet.debit(5, category: :purchase)
        raise ActiveRecord::Rollback
      end
      remembered[:after_a_rolled_back_savepoint] = remembered_stale_snapshots
    end

    remembered.each { |moment, verdicts| assert_equal 1, verdicts.size, "still stale #{moment.to_s.tr("_", " ")}" }
    assert_empty @remembered_after, "gone once the real transaction commits"
  end

  test "the stale verdict lasts exactly as long as its transaction" do
    skip "only MySQL answers plain reads from a stale snapshot" unless mysql?

    stale_command = -> { Wallets::Wallet.find(@wallet.id).reserve(10, category: :booking) }

    after_a_stale_read(stale_command) { |wallet| wallet.debit(5, category: :purchase) }
    assert_equal 1, @remembered_inside.size, "remembered while the transaction runs"
    assert_empty @remembered_after, "forgotten once it commits"

    after_a_stale_read(stale_command) do |wallet|
      wallet.debit(5, category: :purchase)
      @remembered_inside = remembered_stale_snapshots
      raise ActiveRecord::Rollback
    end
    assert_equal 1, @remembered_inside.size
    assert_empty @remembered_after, "forgotten once it rolls back"
  end

  test "the next real transaction on the same connection starts from a clean slate" do
    skip "locking reads are a MySQL concern" unless mysql?

    next_one = nil
    after_a_stale_read(-> { Wallets::Wallet.find(@wallet.id).debit(10, category: :purchase) }, then: -> {
      next_one = capture_sql { Wallets::Wallet.transaction { Wallets::Wallet.find(@wallet.id).debit(10, category: :purchase) } }
    }) { |wallet| wallet.debit(10, category: :purchase) }

    assert_empty locking_ledger_reads(next_one), "a fresh transaction reads plainly"
  end

  # ───────────────────────────────────────────────────────────────────────────
  # A current snapshot costs no extra locks
  # ───────────────────────────────────────────────────────────────────────────

  test "only a stale snapshot turns the ledger reads into locking reads" do
    skip "locking reads are a MySQL concern" unless mysql?

    fresh = capture_sql { Wallets::Wallet.find(@wallet.id).debit(10, category: :purchase) }
    stale = nil
    after_a_stale_read(-> { Wallets::Wallet.find(@wallet.id).reserve(10, category: :booking) }) do |wallet|
      stale = capture_sql { wallet.debit(10, category: :purchase) }
    end

    assert_empty locking_ledger_reads(fresh), "a current snapshot reads plainly"
    refute_empty locking_ledger_reads(stale), "a stale snapshot reads current rows"
  end

  test "concurrent debits on different wallets never deadlock" do
    wallets = Array.new(concurrency) { new_wallet }

    3.times do
      wallets.each { |wallet| wallet.credit(10, category: :reward) }
      outcomes = all_at_once(wallets) { |wallet| Wallets::Wallet.find(wallet.id).debit(10, category: :purchase) }

      assert outcomes.all?(Wallets::Transaction), "unexpected failures: #{outcomes.reject { |outcome| outcome.is_a?(Wallets::Transaction) }.map(&:inspect)}"
    end
  end

  test "concurrent sign-ups with an initial balance never deadlock" do
    # The wallet and its first credit are written inside the owner's own
    # INSERT transaction, after other reads: the snapshot is current (nobody
    # else can even see the wallet yet), so no gap locks are taken.
    signup = Class.new(User) do
      def self.name
        "User"
      end

      has_wallets default_asset: :coins, initial_balance: 50
    end

    outcomes = all_at_once(Array.new(concurrency) { |i| i }) do |i|
      signup.create!(email: "signup-#{i}-#{SecureRandom.hex(4)}@example.com", name: "Sign-up #{i}")
    end
    @owners.concat(outcomes.grep(User))

    assert outcomes.all?(User), "unexpected failures: #{outcomes.reject { |outcome| outcome.is_a?(User) }.map(&:inspect)}"
    assert_equal [50] * concurrency, outcomes.map { |owner| owner.wallet(:coins).balance }
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Row locks serialize writers
  # ───────────────────────────────────────────────────────────────────────────

  test "concurrent debits on one wallet serialize through its row lock, each starting where the last one left it" do
    # With overdrafts allowed nothing refuses a debit, so only the wallet
    # lock keeps two of them from reading the same balance and writing the
    # same snapshot: the snapshots must chain down from zero.
    Wallets.configuration.allow_negative_balance = true
    wallet = new_wallet

    debits = all_at_once(Array.new(concurrency) { |i| i }) { Wallets::Wallet.find(wallet.id).debit(10, category: :purchase) }

    assert debits.all?(Wallets::Transaction), "unexpected failures: #{debits.grep_v(Wallets::Transaction).map(&:inspect)}"
    assert_equal Array.new(concurrency) { |i| [-10 * i, -10 * (i + 1)] }, debits.map { |debit| [debit.balance_before, debit.balance_after] }.sort.reverse
    assert_equal(-10 * concurrency, wallet.reload.balance)
    assert_equal(-10 * concurrency, wallet.read_attribute(:balance), "the cached balance matches the ledger")
  end

  test "concurrent overdraft transfers from one wallet serialize through the pair lock" do
    # The same for transfers, which lock both wallets instead: only the lock
    # keeps two of them from spending the same balance.
    Wallets.configuration.allow_negative_balance = true
    sender = new_wallet
    recipients = Array.new(concurrency) { new_wallet }

    transfers = all_at_once(recipients) do |recipient|
      Wallets::Wallet.find(sender.id).transfer_to(Wallets::Wallet.find(recipient.id), 25, category: :peer_payment)
    end

    assert transfers.all?(Wallets::Transfer), "unexpected failures: #{transfers.grep_v(Wallets::Transfer).map(&:inspect)}"
    outbound = transfers.map(&:outbound_transaction)
    assert_equal Array.new(concurrency) { |i| [-25 * i, -25 * (i + 1)] }, outbound.map { |debit| [debit.balance_before, debit.balance_after] }.sort.reverse
    assert_equal(-25 * concurrency, sender.reload.balance)
    assert_equal(-25 * concurrency, sender.read_attribute(:balance), "the cached balance matches the ledger")
    assert_equal [25] * concurrency, recipients.map(&:balance)
  end

  test "opposing transfers between two wallets serialize without deadlocking" do
    # Each transfer locks the pair in id order, so A to B and B to A can
    # never each hold one row while waiting for the other.
    alice = new_wallet(initial_balance: 100)
    bob = new_wallet(initial_balance: 100)

    8.times do
      transfers = all_at_once([[alice, bob], [bob, alice]]) do |from, to|
        Wallets::Wallet.find(from.id).transfer_to(Wallets::Wallet.find(to.id), 10, category: :peer_payment)
      end

      assert transfers.all?(Wallets::Transfer), "unexpected failures: #{transfers.grep_v(Wallets::Transfer).map(&:inspect)}"
    end

    assert_equal [100, 100], [alice.reload.balance, bob.reload.balance]
    assert_equal [100, 100], [alice.read_attribute(:balance), bob.read_attribute(:balance)], "the cached balances match the ledger"
    assert_equal 16, Wallets::Transfer.where(from_wallet_id: [alice.id, bob.id]).count
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Hold commands against concurrent writers
  # ───────────────────────────────────────────────────────────────────────────

  test "release! after a stale read finds the hold already released and reports nothing" do
    hold = @wallet.hold(@credit, category: :fraud_review)
    released = Queue.new
    Wallets.configuration.on_hold_released { |context| released << context.hold.release_reason }

    outcome = after_a_stale_read(-> { Wallets::Hold.find(hold.id).release!(reason: "first") }) do
      Wallets::Hold.find(hold.id).release!(reason: "second") # active, as this snapshot saw it
    end

    assert_equal "first", outcome.release_reason
    assert_equal ["first"], drain(released)
    assert_equal "first", hold.reload.release_reason
  end

  test "a hold and a debit racing for one credit settle on one outcome with no partial writes" do
    8.times do
      wallet = new_wallet(initial_balance: 100)
      credit = wallet.transactions.credits.sole

      hold, debit = all_at_once(%i[hold debit]) do |command|
        racer = Wallets::Wallet.find(wallet.id)
        if command == :hold
          racer.hold(Wallets::Transaction.find(credit.id), category: :fraud_review)
        else
          racer.debit(100, category: :purchase)
        end
      end

      if hold.is_a?(Wallets::Hold)
        assert_kind_of Wallets::InsufficientBalance, debit, "spending must exclude the held credit"
        assert_empty wallet.transactions.debits
        assert_equal 100, credit.reload.remaining_amount
        assert_equal [hold.id], Wallets::Hold.where(wallet_id: wallet.id).pluck(:id)
      else
        assert_kind_of Wallets::InvalidHold, hold, "nothing was left to hold"
        assert_kind_of Wallets::Transaction, debit
        assert_equal 0, credit.reload.remaining_amount
        assert_empty Wallets::Hold.where(wallet_id: wallet.id)
      end
      assert_equal wallet.balance, wallet.reload.read_attribute(:balance), "the cached balance matches the ledger"
    end
  end

  test "concurrent releases of one hold make one transition and report it once" do
    hold = @wallet.hold(@credit, category: :fraud_review)
    released = Queue.new
    Wallets.configuration.on_hold_released { |context| released << context.hold.release_reason }

    outcomes = all_at_once(Array.new(concurrency) { |i| "releaser-#{i}" }) do |reason|
      Wallets::Hold.find(hold.id).release!(reason: reason)
    end

    assert outcomes.all?(Wallets::Hold), "unexpected failures: #{outcomes.grep_v(Wallets::Hold).map(&:inspect)}"
    winner = hold.reload.release_reason
    assert_equal [winner], drain(released)
    assert_equal [winner] * concurrency, outcomes.map(&:release_reason), "every caller sees the one release"
    assert_equal 100, @wallet.balance
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Targeted debits against concurrent writers
  # ───────────────────────────────────────────────────────────────────────────

  test "a targeted debit sees a reservation committed after its caller's first read" do
    outcome = after_a_stale_read(-> { Wallets::Wallet.find(@wallet.id).reserve(80, category: :booking) }) do |wallet|
      wallet.debit(60, category: :purchase, from: Wallets::Transaction.find(@credit.id))
    rescue Wallets::InsufficientBalance => error
      error
    end

    assert_kind_of Wallets::InsufficientBalance, outcome
    assert_equal "Insufficient balance (20 < 60; 80 reserved)", outcome.message
    assert_empty @wallet.transactions.debits
  end

  test "a targeted debit never takes what a debit committed after its caller's first read already spent" do
    outcome = after_a_stale_read(-> { Wallets::Wallet.find(@wallet.id).debit(60, category: :purchase) }) do |wallet|
      wallet.debit(60, category: :purchase, from: Wallets::Transaction.find(@credit.id))
    rescue Wallets::InsufficientBalance => error
      error
    end

    assert_kind_of Wallets::InsufficientBalance, outcome
    assert_equal "Insufficient balance (40 < 60 in the named credits)", outcome.message
    assert_equal 60, @credit.incoming_allocations.sum(:amount), "the credit is never over-allocated"
  end

  test "a targeted debit sees a hold committed after its caller's first read, and cancels the held value" do
    # With the hold seen, the 30 it takes is held value and needs no funding
    # even though a reservation leaves nothing available.
    @wallet.reserve(100, category: :booking)

    spend = after_a_stale_read(-> { Wallets::Wallet.find(@wallet.id).hold(@credit, category: :fraud_review) }) do |wallet|
      wallet.debit(30, category: :purchase, from: Wallets::Transaction.find(@credit.id))
    end

    assert_equal [[@credit.id, 30]], spend.outgoing_allocations.pluck(:source_transaction_id, :amount)
    assert_equal [-100, 170, 70], [@wallet.balance, @wallet.held_balance, @wallet.total_balance]
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Capture against concurrent writers
  # ───────────────────────────────────────────────────────────────────────────

  test "a capture sees a hold committed after its caller's first read" do
    reservation = @wallet.reserve(80, category: :booking)

    outcome = after_a_stale_read(-> { Wallets::Wallet.find(@wallet.id).hold(category: :chargeback) }) do
      Wallets::Hold.find(reservation.id).capture!(category: :purchase)
    rescue Wallets::InsufficientBalance => error
      error
    end

    assert_kind_of Wallets::InsufficientBalance, outcome
    assert_equal "Insufficient balance (0 < 80 to capture reservation #{reservation.id}; 100 held, 80 reserved)", outcome.message
    assert reservation.reload.active?
    assert_empty @wallet.transactions.debits
  end

  test "a capture after a stale read finds the reservation already captured, creates nothing, and leaves the caller's copy reading the capture" do
    reservation = @wallet.reserve(80, category: :booking)
    winner = nil

    copy, outcome = after_a_stale_read(-> { winner = Wallets::Hold.find(reservation.id).capture!(category: :purchase) }) do
      stale = Wallets::Hold.find(reservation.id) # active, as this snapshot saw it
      begin
        stale.capture!(category: :purchase)
      rescue Wallets::InvalidHold => error
        [stale, error]
      end
    end

    assert_kind_of Wallets::InvalidHold, outcome
    assert_equal "Reservation #{reservation.id} was already captured (transaction #{winner.id})", outcome.message
    assert copy.captured?, "the copy is read back as the ledger has it, never from the old snapshot"
    assert_equal winner.id, copy.capture_transaction_id
    assert_equal "captured", copy.release_reason
    refute copy.active?
    assert_equal [winner.id], @wallet.transactions.debits.pluck(:id)
    assert_equal 20, @wallet.reload.balance
  end

  test "a release that fails after a stale read leaves the caller's copy reading the release that happened" do
    hold = @wallet.hold(@credit, category: :fraud_review)

    copy, outcome = after_a_stale_read(-> { Wallets::Hold.find(hold.id).release!(reason: "first") }) do
      stale = Wallets::Hold.find(hold.id) # active, as this snapshot saw it
      stale.stubs(:lock!).raises(ActiveRecord::LockWaitTimeout, "lock wait timeout")
      begin
        stale.release!(reason: "second")
      rescue ActiveRecord::LockWaitTimeout => error
        [stale, error]
      end
    end

    assert_kind_of ActiveRecord::LockWaitTimeout, outcome
    assert copy.released?, "the copy is read back as the ledger has it, never from the old snapshot"
    refute copy.active?
    assert_equal "first", copy.release_reason
    assert_equal "first", hold.reload.release_reason
  end

  test "a capture after a stale read finds the reservation already released and creates nothing" do
    reservation = @wallet.reserve(60, category: :booking)
    debited = Queue.new
    released = Queue.new
    Wallets.configuration.on_balance_debited { |context| debited << context.transaction.id }
    Wallets.configuration.on_hold_released { |context| released << [context.hold.release_reason, context.transaction&.id] }

    outcome = after_a_stale_read(-> { Wallets::Hold.find(reservation.id).release!(reason: "cancelled") }) do
      Wallets::Hold.find(reservation.id).capture!(category: :purchase) # active, as this snapshot saw it
    rescue Wallets::InvalidHold => error
      error
    end

    assert_kind_of Wallets::InvalidHold, outcome
    assert_empty drain(debited)
    assert_equal [["cancelled", nil]], drain(released), "the release reported itself; the late capture reports nothing"
    assert_equal "cancelled", reservation.reload.release_reason
    refute reservation.captured?
    assert_empty @wallet.transactions.debits
    assert_equal 100, @wallet.balance
  end

  test "a release after a stale read finds the reservation already captured and reports nothing" do
    reservation = @wallet.reserve(60, category: :booking)
    debited = Queue.new
    released = Queue.new
    Wallets.configuration.on_balance_debited { |context| debited << context.transaction.id }
    Wallets.configuration.on_hold_released { |context| released << [context.hold.release_reason, context.transaction&.id] }
    capture = nil

    outcome = after_a_stale_read(-> { capture = Wallets::Hold.find(reservation.id).capture!(category: :purchase) }) do
      Wallets::Hold.find(reservation.id).release!(reason: "cancelled") # active, as this snapshot saw it
    end

    assert_equal "captured", outcome.release_reason, "the late release finds the capture"
    assert_equal capture.id, outcome.capture_transaction_id
    assert_equal [capture.id], drain(debited)
    assert_equal [["captured", capture.id]], drain(released), "the capture reported its release; the late release reports nothing"
    assert_equal [capture.id], @wallet.transactions.debits.pluck(:id)
    assert_equal 40, @wallet.balance
  end

  test "a capture and a release racing for one reservation settle on one terminal transition" do
    debited = Queue.new
    released = Queue.new
    Wallets.configuration.on_balance_debited { |context| debited << context.transaction.id }
    Wallets.configuration.on_hold_released { |context| released << [context.hold.release_reason, context.transaction&.id] }

    8.times do
      wallet = new_wallet(initial_balance: 100)
      reservation = wallet.reserve(60, category: :booking)

      capture, release = all_at_once(%i[capture release]) do |command|
        racer = Wallets::Hold.find(reservation.id)
        (command == :capture) ? racer.capture!(category: :purchase) : racer.release!(reason: "cancelled")
      end

      reservation.reload
      if capture.is_a?(Wallets::Transaction)
        assert_equal [capture.id], drain(debited), "a successful capture reports one debit"
        assert_equal [["captured", capture.id]], drain(released), "and one release, naming it; the late release reports nothing"
        assert_equal "captured", release.release_reason, "the late release finds the capture"
        assert_equal capture.id, reservation.capture_transaction_id
        assert_equal [capture.id], wallet.transactions.debits.pluck(:id)
        assert_equal 40, wallet.balance
      else
        assert_kind_of Wallets::InvalidHold, capture, "a capture after the release creates nothing"
        assert_empty drain(debited)
        assert_equal [["cancelled", nil]], drain(released)
        assert_equal "cancelled", reservation.release_reason
        refute reservation.captured?
        assert_empty wallet.transactions.debits
        assert_equal 100, wallet.balance
      end
      assert_equal wallet.balance, wallet.reload.read_attribute(:balance), "the cached balance matches the ledger"
    end
  end

  test "concurrent captures of one reservation post one debit and report it once" do
    reservation = @wallet.reserve(60, category: :booking)
    debited = Queue.new
    released = Queue.new
    Wallets.configuration.on_balance_debited { |context| debited << context.transaction.id }
    Wallets.configuration.on_hold_released { |context| released << context.transaction.id }

    outcomes = all_at_once(Array.new(concurrency) { |i| i }) do
      Wallets::Hold.find(reservation.id).capture!(category: :purchase)
    end

    captures = outcomes.grep(Wallets::Transaction)
    assert_equal 1, captures.size, "unexpected outcomes: #{outcomes.map(&:inspect)}"
    assert outcomes.grep_v(Wallets::Transaction).all?(Wallets::InvalidHold), "every other attempt is refused: #{outcomes.map(&:inspect)}"
    assert_equal [captures.sole.id], drain(debited)
    assert_equal [captures.sole.id], drain(released)
    assert_equal [captures.sole.id], @wallet.transactions.debits.pluck(:id)
    assert_equal captures.sole.id, reservation.reload.capture_transaction_id
    assert_equal 40, @wallet.reload.balance
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Idempotency keys: duplicates queue on the wallet lock and post once
  # ───────────────────────────────────────────────────────────────────────────

  test "concurrent duplicates of one keyed credit post once and all return it" do
    credited = Queue.new
    Wallets.configuration.on_balance_credited { |context| credited << context.transaction.id }

    outcomes = all_at_once(Array.new(concurrency) { |i| i }) do
      Wallets::Wallet.find(@wallet.id).credit(25, category: :top_up, idempotency_key: "invoice:1")
    end

    assert outcomes.all?(Wallets::Transaction), "unexpected outcomes: #{outcomes.map(&:inspect)}"
    assert_equal 1, outcomes.map(&:id).uniq.size, "every duplicate returns the one credit"
    assert_equal [outcomes.first.id], drain(credited), "and it is reported once"
    assert_equal 125, @wallet.reload.balance
  end

  test "concurrent duplicates of one keyed reservation and its keyed capture each post once" do
    reservations = all_at_once(Array.new(concurrency) { |i| i }) do
      Wallets::Wallet.find(@wallet.id).reserve(60, category: :booking, idempotency_key: "run:1")
    end
    assert reservations.all?(Wallets::Hold), "unexpected outcomes: #{reservations.map(&:inspect)}"
    assert_equal 1, reservations.map(&:id).uniq.size
    assert_equal 1, @wallet.holds.count

    captures = all_at_once(Array.new(concurrency) { |i| i }) do
      Wallets::Hold.find(reservations.first.id).capture!(50, category: :purchase, idempotency_key: "run:1")
    end

    assert captures.all?(Wallets::Transaction), "a keyed retry is answered, never refused: #{captures.map(&:inspect)}"
    assert_equal 1, captures.map(&:id).uniq.size
    assert_equal [captures.first.id], @wallet.transactions.debits.pluck(:id)
    assert_equal 50, @wallet.reload.balance
  end

  test "concurrent duplicates of one keyed transfer move the value once" do
    recipient = new_wallet

    outcomes = all_at_once(Array.new(concurrency) { |i| i }) do
      Wallets::Wallet.find(@wallet.id).transfer_to(Wallets::Wallet.find(recipient.id), 40, idempotency_key: "payment:1")
    end

    assert outcomes.all?(Wallets::Transfer), "unexpected outcomes: #{outcomes.map(&:inspect)}"
    assert_equal 1, outcomes.map(&:id).uniq.size
    assert_equal [60, 40], [@wallet.reload.balance, recipient.reload.balance]
  end

  test "a keyed debit after a stale read finds the debit another connection committed with its key" do
    first = Queue.new
    retry_ = after_a_stale_read(-> { first << Wallets::Wallet.find(@wallet.id).debit(30, category: :purchase, idempotency_key: "order:1") }) do |wallet|
      wallet.debit(30, category: :purchase, idempotency_key: "order:1")
    end

    assert_equal first.pop.id, retry_.id
    assert_equal 70, @wallet.reload.balance
  end

  # ───────────────────────────────────────────────────────────────────────────
  # The races themselves
  # ───────────────────────────────────────────────────────────────────────────

  test "a stale-read race fails at once with the error that ended it, wherever it strikes, and leaves nothing behind" do
    # Neither side may strand the other: a worker that fails before its read
    # must not leave the test waiting for it, and a test whose interleaved
    # write fails must not leave the worker holding its transaction and its
    # connection.
    ran = []

    error = assert_race_fails_cleanly(ActiveRecord::RecordNotFound, "before the worker's read") do
      after_a_stale_read(-> { ran << :interleaved }, wallet: Wallets::Wallet.new) { ran << :block }
    end
    assert_match(/without an ID/, error.message)
    assert_empty ran, "nothing runs once the read failed"

    error = assert_race_fails_cleanly(RuntimeError, "in the interleaved write") do
      after_a_stale_read(-> { raise "the interleaved write failed" }) { ran << :block }
    end
    assert_equal "the interleaved write failed", error.message
    assert_empty ran, "the worker gave up instead of going on"

    error = assert_race_fails_cleanly(RuntimeError, "in the worker's block") do
      after_a_stale_read(-> {}) do |stale|
        stale.debit(10, category: :purchase)
        raise "the block failed"
      end
    end
    assert_equal "the block failed", error.message
    assert_empty @wallet.transactions.debits, "the worker's transaction was rolled back"
  end

  test "a wait that nothing answers gives up with what it waited for, instead of hanging the suite" do
    error = assert_raises(Minitest::Assertion) { await(Queue.new, "an answer", patience: 0.01) }
    assert_equal "Gave up after 0.01 s waiting for an answer", error.message

    error = assert_raises(Minitest::Assertion) { await(Queue.new.tap(&:close), "an answer") }
    assert_equal "Stopped waiting for an answer: the other side gave up", error.message
  end

  test "a race whose racer fails before it is ready fails at once with that error, and leaves nothing behind" do
    pool = ActiveRecord::Base.connection_pool
    pool.stubs(:with_connection).raises(ActiveRecord::ConnectionTimeoutError, "no connection for the racer")

    error = assert_race_fails_cleanly(ActiveRecord::ConnectionTimeoutError, "before the racer is ready") do
      all_at_once([1]) { flunk "a racer that never got ready must never run" }
    end
    assert_equal "no connection for the racer", error.message
  ensure
    pool.unstub(:with_connection) # `transaction` goes through it too, teardown included
  end

  test "every racer holds a connection of its own before any of them starts" do
    # The first racer to start finds every racer's connection checked out:
    # none can finish, and give its connection back, before another has one.
    pool = ActiveRecord::Base.connection_pool
    checked_out = pool.stat[:busy]
    seen_at_start = Queue.new

    all_at_once(Array.new(concurrency) { |i| i }) { seen_at_start << pool.stat[:busy] }

    assert_equal checked_out + concurrency, await(seen_at_start, "the first racer's count")
  end

  private

  def drain(queue)
    Array.new(queue.size) { queue.pop }
  end

  def sqlite?
    ActiveRecord::Base.connection.adapter_name.match?(/sqlite/i)
  end

  def mysql?
    ActiveRecord::Base.connection.adapter_name.match?(/mysql|trilogy/i)
  end

  def new_wallet(initial_balance: 0)
    owner = User.create!(email: "current-reads-#{SecureRandom.hex(6)}@example.com", name: "Current Reads")
    @owners << owner
    create_wallet(owner, asset_code: :current_reads, initial_balance: initial_balance)
  end

  # Runs the block on its own connection, inside a transaction that first
  # takes an ordinary read of `wallet` (fixing a MySQL snapshot) and then
  # waits while `interleaved` commits on this test's connection. Records the
  # stale snapshots the worker remembers inside and after its transaction;
  # `then` runs on the worker's connection once its transaction has ended.
  #
  # An error on either side fails the test with that error, at once, and
  # strands neither side: by the time this returns or raises, the worker has
  # ended, its transaction is committed or rolled back, and its connection
  # is back in the pool.
  def after_a_stale_read(interleaved, wallet: @wallet, joinable: true, then: nil)
    read_taken = Queue.new
    go_on = Queue.new

    worker = Thread.new do
      Thread.current.report_on_exception = false # the test raises what the worker ended with
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        result = Wallets::Wallet.transaction(joinable: joinable) do
          stale = Wallets::Wallet.find(wallet.id)
          stale.balance
          read_taken << connection
          await(go_on, "the interleaved write")
          yield(stale).tap { @remembered_inside = remembered_stale_snapshots }
        end
        @remembered_after = remembered_stale_snapshots
        binding.local_variable_get(:then)&.call
        result
      end
    ensure
      read_taken.close # wakes the test should the worker fail before its read
    end

    worker_connection = await(read_taken, "the worker's first read", from: worker)
    refute_same ActiveRecord::Base.connection, worker_connection, "the worker runs on a connection of its own"
    interleaved.call
    go_on << true
    finish(worker)
  ensure
    go_on.close # a worker still waiting gives up, and its transaction rolls back
    settle(worker)
  end

  # The ledger reads that took row locks, leaving out the two locks every
  # command takes anyway: the wallet row, and the buckets the allocator walks.
  def locking_ledger_reads(statements)
    statements.grep(/FOR UPDATE/).grep_v(/allocatable_amount/).grep_v(/\ASELECT .?wallets_wallets.?\.\*/)
  end

  def remembered_stale_snapshots
    ActiveSupport::IsolatedExecutionState[:wallets_stale_snapshots].to_a
  end

  # One connection stays with the test itself.
  def concurrency
    ActiveRecord::Base.connection_pool.size - 1
  end

  # Runs the block once per item, each on a thread and a connection of its
  # own, and starts them all at the same moment: every racer checks out its
  # connection and reports ready before any is let go, so none can finish
  # before another has even begun. Racers are spawned one at a time, each
  # ready before the next starts (two threads registering a connection at
  # once trip the thread map Rails 8.1.3 falls back to on Ruby below
  # 3.3.5), and a racer that fails before it is ready fails the race at
  # once. Returns each block's result, or the error it raised.
  def all_at_once(items)
    pool = ActiveRecord::Base.connection_pool
    flunk("#{items.size} racers and the test need #{items.size + 1} connections, and the pool has #{pool.size}") if items.size + 1 > pool.size

    ready = Queue.new
    start = Queue.new
    racers = []

    connections = items.map do |item|
      racers << Thread.new do
        Thread.current.report_on_exception = false # the test raises what a racer ended with
        reported = false
        pool.with_connection do |connection|
          ready << connection
          reported = true
          await(start, "the start")
          begin
            yield item
          rescue => error
            error
          end
        end
      ensure
        ready.close unless reported # wakes the test should the racer fail before it is ready
      end
      await(ready, "the racer's connection", from: racers.last)
    end

    assert_equal connections.size, connections.uniq.size, "every racer runs on a connection of its own"
    refute_includes connections, ActiveRecord::Base.connection, "and none on the test's"
    racers.size.times { start << true }
    racers.map { |racer| finish(racer) }
  ensure
    start&.close # racers still waiting give up
    settle(racers)
  end

  # The next value on `queue`, waited for no longer than `patience` seconds.
  # When none comes, a thread `from` that ended with an error fails the test
  # with that error: a sender that fails closes its queue on the way out.
  def await(queue, what, from: [], patience: PATIENCE)
    value = queue.pop(timeout: patience)
    return value unless value.nil?

    Array(from).each { |sender| sender.join(queue.closed? ? patience : 0) }
    flunk(queue.closed? ? "Stopped waiting for #{what}: the other side gave up" : "Gave up after #{patience} s waiting for #{what}")
  end

  # What the thread returned, waited for no longer than PATIENCE. An error
  # it ended with is raised here, as the test's own.
  def finish(thread)
    thread.join(PATIENCE) || flunk("Gave up after #{PATIENCE} s waiting for a racer to finish")
    thread.value
  end

  # Ends every thread before the test does: each gets PATIENCE to end on its
  # own, then is killed, which unwinds it all the same. Either way its
  # transaction is rolled back unless it committed, and its connection goes
  # back to the pool.
  def settle(threads)
    Array(threads).each do |thread|
      thread.join(PATIENCE) || thread.kill.join(PATIENCE)
    rescue Minitest::Assertion, StandardError
      # Raised already by `finish`, or the test is failing for another reason.
    end
  end

  # Runs the race in the block, which must raise `error_class`: at once,
  # with no thread left running, no transaction open and no connection
  # checked out.
  def assert_race_fails_cleanly(error_class, where)
    pool = ActiveRecord::Base.connection_pool
    checked_out = pool.stat[:busy]
    threads = Thread.list
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    error = assert_raises(error_class, "#{where}: its own error fails the test") { yield }

    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, PATIENCE / 2.0, "#{where}: at once, never after a timeout"
    assert_empty Thread.list - threads, "#{where}: no thread left running"
    assert_equal checked_out, pool.stat[:busy], "#{where}: no connection left checked out"
    assert pool.connections.none?(&:transaction_open?), "#{where}: no transaction left open"
    error
  end
end
