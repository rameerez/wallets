# frozen_string_literal: true

require "test_helper"
require "rails/generators"
require "rails/generators/test_case"
require "generators/wallets/upgrade_generator"

class Wallets::UpgradeGeneratorTest < Rails::Generators::TestCase
  tests Wallets::Generators::UpgradeGenerator
  destination File.expand_path("../../tmp/upgrade_generator_sandbox", __dir__)
  setup :prepare_destination

  # These tests issue real DDL. On MySQL, DDL implicitly commits the
  # surrounding transaction, which would corrupt transactional fixtures — so
  # this class runs without them and cleans up its own tables.
  self.use_transactional_tests = false

  teardown do
    Wallets.configuration.table_prefix = "wallets_"
  end

  test "creates the holds migration" do
    Wallets.configuration.table_prefix = "upggen_" # an install without the holds table
    run_generator

    assert_migration "db/migrate/add_wallets_holds.rb" do |migration|
      assert_match(/class AddWalletsHolds < ActiveRecord::Migration\[\d+\.\d+\]/, migration)
      assert_match(/return if table_exists\?\(holds_table\)/, migration)
      assert_match(/add_column wallets_table, :ledger_revision, :bigint, null: false, default: 0/, migration)
      assert_match(/Wallets\.configuration\.table_prefix/, migration)
    end
  end

  test "running the generator again never adds a duplicate migration" do
    Wallets.configuration.table_prefix = "upggen_"
    run_generator
    first_migration = migration_files.sole

    output = run_generator
    assert_equal [first_migration], migration_files
    assert_match(/exist.*add_wallets_holds\.rb/, output)

    # Not even once the existing file no longer matches what the template
    # renders today (a Rails upgrade changes the migration version, an app
    # edits the file). A sentinel line changes it on every Rails version.
    rendered = File.read(first_migration)
    edited = rendered.sub(/^class /, "# Edited by the app after it was generated.\nclass ")
    refute_equal rendered, edited, "the file must really differ from what the template renders"
    File.write(first_migration, edited)

    run_generator
    assert_equal [first_migration], migration_files
    assert_equal edited, File.read(first_migration), "and the edited file is left as it is"
  end

  test "the upgrade gives a 0.3 install exactly the schema a fresh 0.4 install has" do
    Wallets.configuration.table_prefix = "upgcheck_"
    tables = %w[upgcheck_wallets upgcheck_transfers upgcheck_transactions upgcheck_allocations upgcheck_holds]
    run_generator

    with_tables_cleaned_up(tables) do
      # A fresh 0.4 install, minus its holds table and its wallets' ledger
      # revision, is a 0.3 install: 0.4 changes nothing else.
      migrate(install_migration, :up)
      fresh_install = [table_shape("upgcheck_holds"), ledger_revision_shape("upgcheck_")]
      refute_nil fresh_install.last, "a fresh 0.4 install has the ledger revision"
      connection.drop_table("upgcheck_holds")
      connection.remove_column("upgcheck_wallets", :ledger_revision)

      migrate(upgrade_migration, :up)

      assert_equal fresh_install, [table_shape("upgcheck_holds"), ledger_revision_shape("upgcheck_")]
      assert_holds_table_enforces_its_keys("upgcheck_")

      migrate(upgrade_migration, :down)

      refute connection.data_source_exists?("upgcheck_holds")
      assert_nil ledger_revision_shape("upgcheck_"), "back to the 0.3 schema"
      (tables - ["upgcheck_holds"]).each do |table|
        assert connection.data_source_exists?(table), "rolling back the upgrade must leave #{table} alone"
      end
    end
  end

  test "the generator writes no migration when the holds table already exists" do
    # A fresh 0.4 install: this test database already has wallets_holds.
    assert ActiveRecord::Base.connection.table_exists?("wallets_holds")

    output = run_generator

    assert_empty migration_files
    assert_match(/skip.*wallets_holds already exists/, output)
    assert_match(/nothing to migrate/, output)
  end

  test "the generator still writes the migration when the wallets lack their ledger revision" do
    Wallets.configuration.table_prefix = "upgpart_"
    tables = %w[upgpart_wallets upgpart_transactions upgpart_holds]

    with_tables_cleaned_up(tables) do
      create_ledger_tables("upgpart_")
      connection.create_table(:upgpart_holds) { |t| t.string :marker }

      run_generator

      assert_equal 1, migration_files.size
      migrate(upgrade_migration, :up)
      assert ledger_revision_shape("upgpart_"), "the half-upgraded schema is completed"
    end
  end

  test "both migrations recognise MySQL under Rails' Trilogy adapter" do
    # Trilogy reports its own adapter name, and MySQL refuses a default on a
    # JSON column whichever adapter asks. The bundle has no trilogy gem, so
    # the name is stubbed: it is all the migrations look at.
    Wallets.configuration.table_prefix = "upggen_"
    run_generator

    [install_migration, upgrade_migration].each do |migration|
      {"Trilogy" => nil, "Mysql2" => nil, "PostgreSQL" => {}, "SQLite" => {}}.each do |adapter, default|
        migration.stubs(:connection).returns(stub(adapter_name: adapter))
        json_default = migration.send(:json_column_default)

        if default.nil?
          assert_nil json_default, "#{migration.class.name} on #{adapter}"
        else
          assert_equal default, json_default, "#{migration.class.name} on #{adapter}"
        end
      end
    end
  end

  test "the generator still writes the migration when it cannot ask the database" do
    Wallets.configuration.table_prefix = "upggen_"
    ActiveRecord::Base.stubs(:with_connection).raises(ActiveRecord::ConnectionNotEstablished, "no database yet")

    run_generator

    assert_equal 1, migration_files.size
  end

  test "rolling the upgrade back never deletes holds it did not create" do
    # A fresh 0.4 install that ran the upgrade migration anyway: its `up` was
    # a no-op, and its `down` must not take the install's holds with it.
    Wallets.configuration.table_prefix = "upgkeep_"
    tables = %w[upgkeep_wallets upgkeep_transfers upgkeep_transactions upgkeep_allocations upgkeep_holds]
    run_generator

    with_tables_cleaned_up(tables) do
      migrate(install_migration, :up)
      wallets, transactions, holds = models_for("upgkeep_")
      wallet = create_row(wallets, asset_code: "coins", owner_type: "User", owner_id: 1)
      credit = create_row(transactions, wallet_id: wallet.id, amount: 100, category: "credit")
      holds.create!(wallet_id: wallet.id, transaction_id: credit.id, category: "review", metadata: {}, release_metadata: {})

      migrate(upgrade_migration, :up)
      error = assert_raises(ActiveRecord::IrreversibleMigration) { migrate(upgrade_migration, :down) }

      assert_match(/upgkeep_holds still has holds/, error.message)
      assert_equal 1, holds.count, "the hold survives the rollback"

      holds.delete_all
      migrate(upgrade_migration, :down)
      refute connection.data_source_exists?("upgkeep_holds"), "an empty table is dropped"
      assert_nil ledger_revision_shape("upgkeep_"), "and the wallets go back to their 0.3 shape"
    ensure
      [holds, transactions, wallets].each { |model| model&.delete_all if model&.table_exists? }
    end
  end

  test "the upgrade takes a 0.2 install to exactly the schema a fresh 0.4 install has" do
    Wallets.configuration.table_prefix = "upg02_"
    tables = %w[upg02_wallets upg02_transfers upg02_transactions upg02_allocations upg02_holds]
    run_generator

    with_tables_cleaned_up(tables) do
      migrate(install_migration, :up)
      fresh_install = [table_shape("upg02_holds"), ledger_revision_shape("upg02_")]
      migrate(install_migration, :down)

      migrate(install_migration(file_fixture("create_wallets_tables_0_2.rb.erb")), :up)
      assert_empty connection.check_constraints("upg02_transactions"), "a 0.2 schema, before 0.3's check constraints"
      refute connection.data_source_exists?("upg02_holds")
      assert_nil ledger_revision_shape("upg02_")

      migrate(upgrade_migration, :up)

      assert_equal fresh_install, [table_shape("upg02_holds"), ledger_revision_shape("upg02_")]
      assert_holds_table_enforces_its_keys("upg02_")
    end
  end

  test "the upgrade is a no-op when the holds table already exists" do
    Wallets.configuration.table_prefix = "upgnoop_"
    tables = %w[upgnoop_wallets upgnoop_transactions upgnoop_holds]
    run_generator

    with_tables_cleaned_up(tables) do
      create_ledger_tables("upgnoop_")
      connection.create_table(:upgnoop_holds) { |t| t.string :marker }

      migrate(upgrade_migration, :up)

      assert_equal %w[id marker], connection.columns("upgnoop_holds").map(&:name)
      assert_ledger_revision_added("upgnoop_")
    end
  end

  test "foreign keys follow the existing key types, not the current generator settings" do
    # A ledger installed with 4-byte integer keys, in an app that has since
    # switched its generators to uuid keys. MySQL refuses a foreign key across
    # int and bigint, so a migration that guessed would not even run there.
    Wallets.configuration.table_prefix = "upgkeys_"
    tables = %w[upgkeys_wallets upgkeys_transactions upgkeys_holds]
    run_generator
    generators = Rails.configuration.generators
    original_setting = generators.options[generators.orm][:primary_key_type]
    generators.options[generators.orm][:primary_key_type] = :uuid

    with_tables_cleaned_up(tables) do
      create_ledger_tables("upgkeys_", id: :integer)

      migrate(upgrade_migration, :up)

      wallet_key = connection.columns("upgkeys_wallets").find { |column| column.name == "id" }
      transaction_key = connection.columns("upgkeys_transactions").find { |column| column.name == "id" }
      holds = connection.columns("upgkeys_holds").index_by(&:name)

      if sqlite?
        # One integer width: rowid keys are 64-bit, declared as the install
        # template declares its foreign keys.
        %w[wallet_id transaction_id capture_transaction_id].each { |column| assert_equal "bigint", holds[column].sql_type }
      else
        assert_equal wallet_key.sql_type, holds["wallet_id"].sql_type
        assert_equal transaction_key.sql_type, holds["transaction_id"].sql_type
        assert_equal transaction_key.sql_type, holds["capture_transaction_id"].sql_type
      end
      refute_equal "uuid", holds["id"].sql_type, "the holds key follows the ledger, not the generator setting"
      assert_ledger_revision_added("upgkeys_")
      assert_holds_table_enforces_its_keys("upgkeys_")
    end
  ensure
    generators.options[generators.orm][:primary_key_type] = original_setting
  end

  test "a uuid ledger gets uuid hold keys" do
    skip "uuid primary keys are a PostgreSQL feature" unless postgresql?

    Wallets.configuration.table_prefix = "upguuid_"
    tables = %w[upguuid_wallets upguuid_transactions upguuid_holds]
    run_generator

    with_tables_cleaned_up(tables) do
      create_ledger_tables("upguuid_", id: :uuid)

      migrate(upgrade_migration, :up)

      holds = connection.columns("upguuid_holds").index_by(&:name)
      %w[id wallet_id transaction_id capture_transaction_id].each do |column|
        assert_equal "uuid", holds[column].sql_type, "#{column} must be a uuid"
      end
      assert_ledger_revision_added("upguuid_")
      assert_holds_table_enforces_its_keys("upguuid_")
    end
  end

  test "an unsigned MySQL ledger gets unsigned hold keys" do
    skip "unsigned integers are a MySQL feature" unless mysql?

    Wallets.configuration.table_prefix = "upgunsigned_"
    tables = %w[upgunsigned_wallets upgunsigned_transactions upgunsigned_holds]
    run_generator

    with_tables_cleaned_up(tables) do
      create_ledger_tables("upgunsigned_", id: :bigint, unsigned: true)

      migrate(upgrade_migration, :up)

      holds = connection.columns("upgunsigned_holds").index_by(&:name)
      %w[wallet_id transaction_id capture_transaction_id].each do |column|
        assert holds[column].unsigned?, "#{column} must be unsigned to reference an unsigned key"
      end
      assert_ledger_revision_added("upgunsigned_")
      assert_holds_table_enforces_its_keys("upgunsigned_")
    end
  end

  private

  def connection
    ActiveRecord::Base.connection
  end

  def postgresql?
    connection.adapter_name.match?(/postg/i)
  end

  def sqlite?
    connection.adapter_name.match?(/sqlite/i)
  end

  def mysql?
    connection.adapter_name.match?(/mysql|trilogy/i)
  end

  def migration_files
    Dir.glob(File.join(destination_root, "db/migrate/*_add_wallets_holds.rb"))
  end

  # Loaded under a sandbox module so the tests never touch a global constant.
  def upgrade_migration
    sandbox = Module.new
    load migration_files.sole, sandbox
    sandbox.const_get(:AddWalletsHolds).new
  end

  def install_migration(template = File.expand_path("../../lib/generators/wallets/templates/create_wallets_tables.rb.erb", __dir__))
    path = File.join(destination_root, "create_wallets_tables.rb")
    File.write(path, ERB.new(File.read(template), trim_mode: "-").result_with_hash(migration_version: "[#{ActiveRecord::VERSION::STRING.to_f}]"))

    sandbox = Module.new
    load path, sandbox
    sandbox.const_get(:CreateWalletsTables).new
  end

  def migrate(migration, direction)
    ActiveRecord::Migration.suppress_messages { migration.migrate(direction) }
  end

  # The two tables the upgrade references, shaped the way any earlier
  # install made them.
  def create_ledger_tables(prefix, **key_options)
    connection.create_table(:"#{prefix}wallets", **key_options) { |t| t.string :asset_code }
    connection.create_table(:"#{prefix}transactions", **key_options) { |t| t.bigint :amount }
  end

  def table_shape(table)
    {
      columns: connection.columns(table).map { |column| [column.name, column.sql_type, column.null, column.default] }.sort_by(&:first),
      indexes: connection.indexes(table).map { |index| [index.name, index.columns, index.unique] }.sort_by(&:first),
      check_constraints: connection.check_constraints(table).map { |check| [check.name, check.expression] }.sort_by(&:first),
      foreign_keys: connection.foreign_keys(table).map { |key| [key.column, key.to_table, key.primary_key] }.sort_by(&:first)
    }
  end

  # Inserting through real keys proves every foreign key column can hold the
  # key it references, and that the check constraints are live.
  def assert_holds_table_enforces_its_keys(prefix)
    wallets, transactions, holds = models_for(prefix)

    wallet = create_row(wallets, asset_code: "coins", owner_type: "User", owner_id: 1)
    credit = create_row(transactions, wallet_id: wallet.id, amount: 100, category: "credit")
    debit = create_row(transactions, wallet_id: wallet.id, amount: -60, category: "debit")

    json = {metadata: {}, release_metadata: {}}
    holds.create!(wallet_id: wallet.id, transaction_id: credit.id, category: "review", **json)
    holds.create!(wallet_id: wallet.id, amount: 60, category: "booking", released_at: Time.current, capture_transaction_id: debit.id, **json)

    assert_raises(ActiveRecord::StatementInvalid) do
      holds.create!(wallet_id: wallet.id, transaction_id: credit.id, amount: 5, category: "review", **json)
    end
    assert_equal 2, holds.count
  ensure
    [holds, transactions, wallets].each { |model| model&.delete_all }
  end

  # The wallets' ledger revision as a migration left it, or nil.
  def ledger_revision_shape(prefix)
    column = connection.columns("#{prefix}wallets").find { |candidate| candidate.name == "ledger_revision" }
    column && [column.sql_type, column.null, column.default]
  end

  # A 64-bit integer, never null, starting at 0, on any adapter.
  def assert_ledger_revision_added(prefix)
    column = connection.columns("#{prefix}wallets").find { |candidate| candidate.name == "ledger_revision" }

    assert column, "#{prefix}wallets must get a ledger revision"
    assert_equal [:integer, 8, false, "0"], [column.type, column.limit || 8, column.null, column.default.to_s]
  end

  # Bare models over a prefixed ledger's wallets, transactions and holds.
  def models_for(prefix)
    %w[wallets transactions holds].map do |suffix|
      Class.new(ActiveRecord::Base) { self.table_name = "#{prefix}#{suffix}" }.tap(&:reset_column_information)
    end
  end

  # Fills the columns a full install requires; the bare tables built by
  # `create_ledger_tables` simply have fewer of them.
  def create_row(model, **attributes)
    attributes[:metadata] = {} if model.column_names.include?("metadata")
    model.create!(attributes.select { |name, _value| model.column_names.include?(name.to_s) })
  end

  def with_tables_cleaned_up(tables)
    yield
  ensure
    ActiveRecord::Migration.suppress_messages do
      tables.reverse_each { |table| connection.drop_table(table, if_exists: true) }
    end
  end
end
