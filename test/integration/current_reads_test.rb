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
# credit, and against each other on one hold. PostgreSQL reads current rows
# per statement and runs every test as well. SQLite serializes writers for the
# whole database, so none of these interleavings can exist there.
class CurrentReadsTest < ActiveSupport::TestCase
  # Real connections must see each other's commits.
  self.use_transactional_tests = false

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
  def after_a_stale_read(interleaved, wallet: @wallet, joinable: true, then: nil)
    read_taken = Queue.new
    go_on = Queue.new

    worker = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        result = Wallets::Wallet.transaction(joinable: joinable) do
          stale = Wallets::Wallet.find(wallet.id)
          stale.balance
          read_taken << true
          go_on.pop
          yield(stale).tap { @remembered_inside = remembered_stale_snapshots }
        end
        @remembered_after = remembered_stale_snapshots
        binding.local_variable_get(:then)&.call
        result
      end
    end

    read_taken.pop
    interleaved.call
    go_on << true
    worker.value
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

  # Releases one thread per item at the same moment; returns each block's
  # result, or the error it raised.
  def all_at_once(items)
    gate = Queue.new
    threads = items.map do |item|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          gate.pop
          yield item
        rescue => error
          error
        end
      end
    end
    items.size.times { gate << true }
    threads.map(&:value)
  end
end
