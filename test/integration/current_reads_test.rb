# frozen_string_literal: true

require "test_helper"

# A wallet command may run inside a caller's transaction that has already
# read something. Under MySQL's default repeatable read that first read fixes
# the transaction's snapshot, and taking the wallet lock afterwards does not
# refresh it: a mutation that finds its snapshot stale must read current rows.
# These tests interleave real connections to prove it, and prove the converse
# too: commands whose snapshot is current take no extra locks, because extra
# InnoDB gap locks deadlock unrelated wallets. PostgreSQL reads current rows
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
    outcome = after_a_stale_read(-> { like_a_command(@wallet) { reservation!(@wallet, 80) } }) do |wallet|
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

    spend = after_a_stale_read(-> { like_a_command(@wallet) { hold!(@wallet, @credit) } }) do |wallet|
      wallet.debit(30, category: :purchase)
    end

    assert_empty spend.outgoing_allocations, "the covered credit is not eligible"
    assert_equal 30, spend.unbacked_amount
    assert_equal 100, @credit.reload.remaining_amount
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

  test "the stale verdict lasts exactly as long as its transaction" do
    skip "only MySQL answers plain reads from a stale snapshot" unless mysql?

    stale_command = -> { like_a_command(@wallet) { reservation!(@wallet, 10) } }

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

  # ───────────────────────────────────────────────────────────────────────────
  # A current snapshot costs no extra locks
  # ───────────────────────────────────────────────────────────────────────────

  test "only a stale snapshot turns the ledger reads into locking reads" do
    skip "locking reads are a MySQL concern" unless mysql?

    fresh = capture_sql { Wallets::Wallet.find(@wallet.id).debit(10, category: :purchase) }
    stale = nil
    after_a_stale_read(-> { like_a_command(@wallet) { reservation!(@wallet, 10) } }) do |wallet|
      stale = capture_sql { wallet.debit(10, category: :purchase) }
    end

    assert_empty fresh.grep(/\ASELECT SUM.*FOR UPDATE/m), "a current snapshot reads plainly"
    refute_empty stale.grep(/\ASELECT SUM.*FOR UPDATE/m), "a stale snapshot reads current rows"
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

  private

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

  # Writes the way a wallet command does: under the wallet lock, refreshing
  # the wallet row on the way out.
  def like_a_command(wallet)
    locked = Wallets::Wallet.find(wallet.id)
    locked.with_lock do
      yield
      locked.send(:refresh_cached_balance!)
    end
  end

  # Runs the block on its own connection, inside a transaction that first
  # takes an ordinary read of the wallet (fixing a MySQL snapshot) and then
  # waits while `interleaved` commits on this test's connection. Records the
  # stale snapshots the worker remembers inside and after its transaction.
  def after_a_stale_read(interleaved)
    read_taken = Queue.new
    go_on = Queue.new

    worker = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        result = Wallets::Wallet.transaction do
          wallet = Wallets::Wallet.find(@wallet.id)
          wallet.balance
          read_taken << true
          go_on.pop
          yield(wallet).tap { @remembered_inside = remembered_stale_snapshots }
        end
        @remembered_after = remembered_stale_snapshots
        result
      end
    end

    read_taken.pop
    interleaved.call
    go_on << true
    worker.value
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
