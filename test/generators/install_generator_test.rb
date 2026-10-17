# frozen_string_literal: true

require "test_helper"
require "rails/generators"
require "rails/generators/test_case"
require "generators/wallets/install_generator"

class Wallets::InstallGeneratorTest < Rails::Generators::TestCase
  tests Wallets::Generators::InstallGenerator
  destination File.expand_path("../../tmp/generator_sandbox", __dir__)
  setup :prepare_destination

  # The migration-execution test issues real DDL. On MySQL, DDL implicitly
  # commits the surrounding transaction, which would corrupt transactional
  # fixtures — so this class runs without them.
  self.use_transactional_tests = false

  test "creates the migration and the initializer" do
    run_generator

    assert_migration "db/migrate/create_wallets_tables.rb" do |migration|
      assert_match(/class CreateWalletsTables < ActiveRecord::Migration\[\d+\.\d+\]/, migration)
      assert_match(/create_table wallets_table/, migration)
      assert_match(/Wallets\.configuration\.table_prefix/, migration)
    end

    assert_file "config/initializers/wallets.rb" do |initializer|
      assert_match(/Wallets\.configure do \|config\|/, initializer)
      assert_match(/config\.default_asset = :credits/, initializer)
    end
  end

  test "generated migration creates and drops all five tables against a real database" do
    run_generator
    migration_path = Dir.glob(File.join(destination_root, "db/migrate/*_create_wallets_tables.rb")).sole

    Wallets.configuration.table_prefix = "gencheck_"
    tables = %w[gencheck_wallets gencheck_transfers gencheck_transactions gencheck_allocations gencheck_holds]
    connection = ActiveRecord::Base.connection

    begin
      # Load the migration under a sandbox module so the test never touches
      # the global CreateWalletsTables constant.
      sandbox = Module.new
      load migration_path, sandbox
      migration = sandbox.const_get(:CreateWalletsTables).new

      ActiveRecord::Migration.suppress_messages do
        migration.migrate(:up)
        tables.each { |table| assert connection.data_source_exists?(table), "expected #{table} to be created" }
        revision = connection.columns("gencheck_wallets").find { |column| column.name == "ledger_revision" }
        assert_equal [:integer, false, "0"], [revision&.type, revision&.null, revision&.default.to_s], "a fresh install keeps a ledger revision"
        assert connection.indexes("gencheck_transactions").any?, "expected indexes on gencheck_transactions"
        assert connection.indexes("gencheck_transfers").any?, "expected indexes on gencheck_transfers"
        assert connection.check_constraint_exists?(
          "gencheck_transactions",
          name: "check_gencheck_transactions_amount_nonzero"
        )
        assert connection.check_constraint_exists?(
          "gencheck_allocations",
          name: "check_gencheck_allocations_amount_positive"
        )
        %w[amount_positive credit_hold_has_no_amount capture_ends_reservation].each do |suffix|
          assert connection.check_constraint_exists?("gencheck_holds", name: "check_gencheck_holds_#{suffix}"),
            "expected the #{suffix} check on gencheck_holds"
        end
        assert_equal %w[gencheck_transactions gencheck_transactions gencheck_wallets],
          connection.foreign_keys("gencheck_holds").map(&:to_table).sort
        assert_equal(
          %w[
            index_gencheck_holds_on_capture_tx
            index_gencheck_holds_on_releases_at
            index_gencheck_holds_on_tx_and_released_at
            index_gencheck_holds_on_wallet_and_released_at
          ],
          connection.indexes("gencheck_holds").map(&:name).sort
        )

        migration.migrate(:down)
        tables.each { |table| refute connection.data_source_exists?(table), "expected #{table} to be dropped" }
      end
    ensure
      ActiveRecord::Migration.suppress_messages do
        tables.reverse_each { |table| connection.drop_table(table, if_exists: true) }
      end
      Wallets.configuration.table_prefix = "wallets_"
    end
  end
end
