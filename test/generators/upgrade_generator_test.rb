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
    run_generator

    assert_migration "db/migrate/add_wallets_holds.rb" do |migration|
      assert_match(/class AddWalletsHolds < ActiveRecord::Migration\[\d+\.\d+\]/, migration)
      assert_match(/return if table_exists\?\(holds_table\)/, migration)
      assert_match(/Wallets\.configuration\.table_prefix/, migration)
    end
  end

  test "running the generator again never adds a duplicate migration" do
    run_generator
    first_migration = migration_files.sole

    output = run_generator
    assert_equal [first_migration], migration_files
    assert_match(/exist.*add_wallets_holds\.rb/, output)

    # Not even once the existing file no longer matches what the template
    # renders today (a Rails upgrade changes the migration version).
    File.write(first_migration, File.read(first_migration).sub(/Migration\[\d+\.\d+\]/, "Migration[7.2]"))
    run_generator
    assert_equal [first_migration], migration_files
  end

  test "the upgrade gives a 0.3 install exactly the holds table a fresh 0.4 install has" do
    Wallets.configuration.table_prefix = "upgcheck_"
    tables = %w[upgcheck_wallets upgcheck_transfers upgcheck_transactions upgcheck_allocations upgcheck_holds]
    run_generator

    with_tables_cleaned_up(tables) do
      # A fresh 0.4 install, minus its holds table, is a 0.3 install: 0.4
      # changes nothing else.
      migrate(install_migration, :up)
      fresh_install = table_shape("upgcheck_holds")
      connection.drop_table("upgcheck_holds")

      migrate(upgrade_migration, :up)

      assert_equal fresh_install, table_shape("upgcheck_holds")
      assert_holds_table_enforces_its_keys("upgcheck_")

      migrate(upgrade_migration, :down)

      refute connection.data_source_exists?("upgcheck_holds")
      (tables - ["upgcheck_holds"]).each do |table|
        assert connection.data_source_exists?(table), "rolling back the upgrade must leave #{table} alone"
      end
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

  def install_migration
    template = File.expand_path("../../lib/generators/wallets/templates/create_wallets_tables.rb.erb", __dir__)
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
    wallets = Class.new(ActiveRecord::Base) { self.table_name = "#{prefix}wallets" }
    transactions = Class.new(ActiveRecord::Base) { self.table_name = "#{prefix}transactions" }
    holds = Class.new(ActiveRecord::Base) { self.table_name = "#{prefix}holds" }
    [wallets, transactions, holds].each(&:reset_column_information)

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
