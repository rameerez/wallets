# frozen_string_literal: true

require "test_helper"

class Wallets::HoldTest < ActiveSupport::TestCase
  setup do
    @wallet = create_wallet(users(:new_user), asset_code: :points)
    @credit = @wallet.credit(100, category: :reward)
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Shapes and row-local validations
  # ───────────────────────────────────────────────────────────────────────────

  test "a credit hold, a wallet hold and a reservation are the three valid shapes" do
    credit_hold = hold!(@wallet, @credit)
    wallet_hold = hold!(@wallet)
    reservation = reservation!(@wallet, 30)

    assert credit_hold.credit_scoped?
    assert credit_hold.coverage?
    refute credit_hold.reservation?
    refute credit_hold.wallet_scoped?

    assert wallet_hold.wallet_scoped?
    assert wallet_hold.coverage?
    refute wallet_hold.reservation?
    refute wallet_hold.credit_scoped?

    assert reservation.wallet_scoped?
    assert reservation.reservation?
    refute reservation.coverage?
    assert_equal 30, reservation.reload.amount
  end

  test "category is required" do
    [nil, "", "   "].each do |blank|
      hold = Wallets::Hold.new(wallet: @wallet, category: blank)

      refute hold.valid?, "category #{blank.inspect} must be rejected"
      assert_includes hold.errors[:category], "can't be blank"
    end
  end

  test "category is normalized to a stripped string" do
    assert_equal "fraud_review", hold!(@wallet, category: :fraud_review).reload.category
    assert_equal "pending validation", hold!(@wallet, category: "  pending validation ").reload.category
    assert_equal "42", hold!(@wallet, category: 42).reload.category
  end

  test "category is a free-form reason: not a transaction category, and repeatable on one credit" do
    first = hold!(@wallet, @credit, category: :not_a_transaction_category)
    second = hold!(@wallet, @credit, category: :not_a_transaction_category)

    assert first.persisted?
    assert second.persisted?
    assert_equal 2, @credit.holds.count
  end

  test "amount is nil or a positive whole number" do
    [1, 3_000, 10.0, "25", BigDecimal(7)].each do |amount|
      hold = Wallets::Hold.new(wallet: @wallet, category: :booking, amount: amount)

      assert hold.valid?, "amount #{amount.inspect} must be accepted: #{hold.errors.full_messages.to_sentence}"
    end

    assert Wallets::Hold.new(wallet: @wallet, category: :review, amount: nil).valid?
    assert_equal 10, reservation!(@wallet, 10.0).reload.amount
  end

  test "amount rejects zero and negatives" do
    [0, -1, "-5"].each do |amount|
      hold = Wallets::Hold.new(wallet: @wallet, category: :booking, amount: amount)

      refute hold.valid?, "amount #{amount.inspect} must be rejected"
      assert_includes hold.errors[:amount], "must be greater than 0"
    end
  end

  test "amount rejects fractions and non-numbers instead of turning them into a coverage hold" do
    # The integer column casts every one of these to nil (or truncates it),
    # which on its own would make a mistyped reservation a silent hold over
    # the whole wallet.
    [10.5, "10.5", "ten", "", Float::INFINITY, Float::NAN, :ten, Object.new].each do |amount|
      hold = Wallets::Hold.new(wallet: @wallet, category: :booking, amount: amount)

      refute hold.valid?, "amount #{amount.inspect} must be rejected"
      assert_includes hold.errors[:amount], "must be an integer"
    end
  end

  test "a credit hold cannot carry an amount" do
    hold = Wallets::Hold.new(wallet: @wallet, credit: @credit, category: :review, amount: 40)

    refute hold.valid?
    assert_includes hold.errors[:amount], "must be blank on a credit hold"
  end

  test "only an ended reservation can name the debit it was captured into" do
    debit = @wallet.debit(40, category: :purchase)

    coverage = Wallets::Hold.new(wallet: @wallet, category: :review, released_at: Time.current, capture_transaction: debit)
    refute coverage.valid?
    assert_includes coverage.errors[:amount], "can't be blank on a captured reservation"

    credit_hold = Wallets::Hold.new(wallet: @wallet, credit: @credit, category: :review, released_at: Time.current, capture_transaction: debit)
    refute credit_hold.valid?
    assert_includes credit_hold.errors[:transaction_id], "must be blank on a captured reservation"

    open_reservation = Wallets::Hold.new(wallet: @wallet, amount: 40, category: :booking, capture_transaction: debit)
    refute open_reservation.valid?
    assert_includes open_reservation.errors[:released_at], "can't be blank on a captured reservation"

    ended_reservation = Wallets::Hold.new(wallet: @wallet, amount: 40, category: :booking, released_at: Time.current, release_reason: "captured", capture_transaction: debit)
    assert ended_reservation.valid?, ended_reservation.errors.full_messages.to_sentence
  end

  test "a hold needs a wallet, while the credit and the capture debit are optional" do
    orphan = Wallets::Hold.new(category: :review)

    refute orphan.valid?
    assert orphan.errors[:wallet].any?
    assert_empty orphan.errors[:credit]
    assert_empty orphan.errors[:capture_transaction]
  end

  test "the database enforces the same shape the model validates" do
    debit = @wallet.debit(10, category: :purchase)
    invalid_rows = {
      "a zero amount" => {amount: 0},
      "a negative amount" => {amount: -5},
      "an amount on a credit hold" => {credit: @credit, amount: 5},
      "a capture link on a coverage hold" => {released_at: Time.current, capture_transaction: debit},
      "a capture link on an open reservation" => {amount: 10, capture_transaction: debit},
      "a capture link on a credit hold" => {credit: @credit, released_at: Time.current, capture_transaction: debit}
    }

    invalid_rows.each do |description, attributes|
      hold = Wallets::Hold.new(wallet: @wallet, category: :review, **attributes)

      assert_raises(ActiveRecord::StatementInvalid, "the database must refuse #{description}") do
        Wallets::Hold.transaction(requires_new: true) { hold.save!(validate: false) }
      end
    end
  end

  test "a debit can be the capture of one reservation only" do
    debit = @wallet.debit(40, category: :purchase)
    reservation!(@wallet, 40, released_at: Time.current, release_reason: "captured", capture_transaction: debit)
    second = Wallets::Hold.new(wallet: @wallet, amount: 40, category: :booking, released_at: Time.current, capture_transaction: debit)

    assert_raises(ActiveRecord::RecordNotUnique) do
      Wallets::Hold.transaction(requires_new: true) { second.save!(validate: false) }
    end
  end

  test "foreign keys refuse a hold that points at nothing" do
    missing_id = Wallets::Transaction.maximum(:id).to_i + 1_000

    {wallet_id: Wallets::Wallet.maximum(:id).to_i + 1_000, transaction_id: missing_id, capture_transaction_id: missing_id}.each do |column, value|
      # Raw ids only: an assigned association would write its own id back.
      attributes = {wallet_id: @wallet.id, category: :review}
      if column == :capture_transaction_id
        attributes[:amount] = 10
        attributes[:released_at] = Time.current
      end
      hold = Wallets::Hold.new(**attributes, column => value)

      assert_raises(ActiveRecord::InvalidForeignKey, "#{column} must reference an existing row") do
        Wallets::Hold.transaction(requires_new: true) { hold.save!(validate: false) }
      end
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Lifecycle: scopes and predicates
  # ───────────────────────────────────────────────────────────────────────────

  test "a hold is inactive exactly at its deadline, like an expiring credit" do
    freeze_time
    deadline = 1.hour.from_now
    hold = hold!(@wallet, @credit, releases_at: deadline)

    travel_to(deadline - 1.second) do
      assert hold.active?
      refute hold.lapsed?
      assert_includes Wallets::Hold.active, hold
    end

    travel_to(deadline) do
      refute hold.active?
      assert hold.lapsed?
      refute hold.released?
      assert_not_includes Wallets::Hold.active, hold
    end
  end

  test "active? and active evaluate at a given instant" do
    freeze_time
    hold = hold!(@wallet, releases_at: 2.days.from_now)

    assert hold.active?(at: 1.day.from_now)
    refute hold.active?(at: 2.days.from_now)
    assert hold.lapsed?(at: 3.days.from_now)
    refute hold.lapsed?(at: 1.day.from_now)
    assert_includes Wallets::Hold.active(at: 1.day.from_now), hold
    assert_not_includes Wallets::Hold.active(at: 2.days.from_now), hold
  end

  test "released, lapsed and active describe every state of a hold" do
    freeze_time
    open_ended = hold!(@wallet)
    scheduled = hold!(@wallet, releases_at: 1.day.from_now)
    released = hold!(@wallet, released_at: 1.minute.ago, release_reason: "cleared_by_operator")
    lapsed = hold!(@wallet, releases_at: 1.minute.ago)
    released_before_lapsing = hold!(@wallet, releases_at: 1.minute.ago, released_at: 1.hour.ago)

    assert_equal [open_ended, scheduled].map(&:id).sort, Wallets::Hold.where(wallet: @wallet).active.pluck(:id).sort
    assert_equal [released, released_before_lapsing].map(&:id).sort, Wallets::Hold.where(wallet: @wallet).released.pluck(:id).sort

    assert [open_ended, scheduled].all?(&:active?)
    assert [released, released_before_lapsing].all?(&:released?)
    assert lapsed.lapsed?
    refute lapsed.released?
    refute released_before_lapsing.lapsed?, "an explicit release is a release, not a lapse"
    refute released.active?
  end

  test "coverage, reservations, for_wallet_scope and credit_scoped split holds by shape" do
    credit_hold = hold!(@wallet, @credit)
    wallet_hold = hold!(@wallet)
    reservation = reservation!(@wallet, 25)
    holds = Wallets::Hold.where(wallet: @wallet)

    assert_equal [credit_hold, wallet_hold].map(&:id).sort, holds.coverage.pluck(:id).sort
    assert_equal [reservation.id], holds.reservations.pluck(:id)
    assert_equal [wallet_hold, reservation].map(&:id).sort, holds.for_wallet_scope.pluck(:id).sort
    assert_equal [credit_hold.id], holds.credit_scoped.pluck(:id)
    assert_equal [wallet_hold.id], holds.coverage.for_wallet_scope.pluck(:id)
  end

  test "scopes stay qualified when joined with a table that shares their column names" do
    # Transactions also have `amount` and `id`; unqualified predicates would
    # be ambiguous (or silently wrong) here.
    credit_hold = hold!(@wallet, @credit)
    reservation!(@wallet, 25)

    joined = Wallets::Hold.joins(:credit).active.coverage.credit_scoped.where(Wallets::Transaction.arel_table[:amount].gt(0))

    assert_equal [credit_hold.id], joined.pluck(Wallets::Hold.arel_table[:id])
  end

  test "captured? follows the capture link" do
    debit = @wallet.debit(40, category: :purchase)
    open_reservation = reservation!(@wallet, 40)
    captured = reservation!(@wallet, 40, released_at: Time.current, release_reason: "captured", capture_transaction: debit)

    refute open_reservation.captured?
    assert captured.captured?
    assert captured.released?
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Metadata and release metadata
  # ───────────────────────────────────────────────────────────────────────────

  test "both JSON columns read as empty hashes by default, including after reload" do
    hold = hold!(@wallet)

    [hold, hold.reload, Wallets::Hold.find(hold.id)].each do |record|
      assert_equal({}, record.metadata)
      assert_equal({}, record.release_metadata)
      assert_kind_of ActiveSupport::HashWithIndifferentAccess, record.release_metadata
    end
  end

  test "a NULL JSON column reads as an empty hash and is saved as one" do
    # MySQL gives JSON columns no default, so a NULL must never reach the
    # NOT NULL column.
    hold = Wallets::Hold.new(wallet: @wallet, category: :review)
    hold.send(:write_attribute, :metadata, nil)
    hold.send(:write_attribute, :release_metadata, nil)

    assert_equal({}, hold.metadata)
    assert_equal({}, hold.release_metadata)

    hold.save!

    assert_equal({}, Wallets::Hold.find(hold.id).release_metadata)
    assert_equal({}, Wallets::Hold.find(hold.id).metadata)
  end

  test "both JSON columns read with indifferent access and persist in-place changes" do
    hold = hold!(@wallet, metadata: {"case_id" => 7})

    assert_equal 7, hold.metadata[:case_id]

    hold.metadata[:reviewer] = "ana"
    hold.release_metadata[:actor_id] = 12
    hold.save!

    reloaded = Wallets::Hold.find(hold.id)
    assert_equal({"case_id" => 7, "reviewer" => "ana"}, reloaded.metadata)
    assert_equal({"actor_id" => 12}, reloaded.release_metadata)
    assert_equal 12, reloaded.release_metadata[:actor_id]
  end

  test "both JSON columns accept anything hash-like and coerce the rest to an empty hash" do
    hold = hold!(@wallet)

    hold.update!(metadata: [[:origin, "api"]], release_metadata: {reason: "cleared"})
    assert_equal({"origin" => "api"}, hold.reload.metadata)
    assert_equal "cleared", hold.release_metadata[:reason]

    hold.update!(metadata: "not a hash", release_metadata: nil)
    assert_equal({}, hold.reload.metadata)
    assert_equal({}, hold.release_metadata)
  end

  test "release metadata never touches the creation metadata" do
    hold = hold!(@wallet, metadata: {case_id: 7})

    hold.update!(released_at: Time.current, release_reason: "cleared", release_metadata: {actor_id: 12})

    reloaded = hold.reload
    assert_equal({"case_id" => 7}, reloaded.metadata)
    assert_equal({"actor_id" => 12}, reloaded.release_metadata)
  end

  test "reload drops unsaved in-place changes to both JSON columns" do
    hold = hold!(@wallet, metadata: {case_id: 7}, release_metadata: {note: "kept"})

    hold.metadata[:case_id] = 8
    hold.release_metadata[:note] = "unsaved"
    hold.reload

    assert_equal 7, hold.metadata[:case_id]
    assert_equal "kept", hold.release_metadata[:note]
  end

  test "the metadata concern keeps behaving the same on the other ledger models" do
    # Generalizing the concern for `release_metadata` must leave `metadata`
    # untouched everywhere else.
    assert_equal [:metadata], Wallets::Wallet.metadata_column_names
    assert_equal [:metadata], Wallets::Transaction.metadata_column_names
    assert_equal [:metadata], Wallets::Transfer.metadata_column_names
    assert_equal [:metadata, :release_metadata], Wallets::Hold.metadata_column_names

    @credit.metadata[:audited] = true
    @credit.save!
    assert Wallets::Transaction.find(@credit.id).metadata[:audited]
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Associations and embedding
  # ───────────────────────────────────────────────────────────────────────────

  test "a hold belongs to its wallet and to the credit it covers, and both reach it back" do
    credit_hold = hold!(@wallet, @credit)
    wallet_hold = hold!(@wallet)

    assert_equal @wallet, credit_hold.wallet
    assert_equal @credit, credit_hold.credit
    assert_nil wallet_hold.credit
    assert_equal [credit_hold], @credit.holds.to_a
    assert_equal [credit_hold, wallet_hold].map(&:id).sort, @wallet.holds.pluck(:id).sort
  end

  test "a captured reservation and its debit reach each other" do
    debit = @wallet.debit(40, category: :purchase)
    reservation = reservation!(@wallet, 40, released_at: Time.current, release_reason: "captured", capture_transaction: debit)

    assert_equal debit, reservation.reload.capture_transaction
    assert_equal reservation, debit.reload.captured_reservation
    assert_nil @credit.captured_reservation
  end

  test "HoldBase is abstract and embeddable like the other ledger models" do
    custom_config = Struct.new(:table_prefix).new("custom_")
    derived = Class.new(Wallets::HoldBase) { self.config_provider = -> { custom_config } }
    explicit = Class.new(Wallets::HoldBase) { self.embedded_table_name = "my_holds" }

    assert_predicate Wallets::HoldBase, :abstract_class?
    assert_equal Wallets::Hold, Wallets::Hold.base_class
    assert_equal "wallets_holds", Wallets::Hold.table_name
    assert_equal "custom_holds", derived.table_name
    assert_equal "my_holds", explicit.table_name
  end
end
