# frozen_string_literal: true

require "test_helper"

class Wallets::InstallTemplatesTest < ActiveSupport::TestCase
  test "migration template uses the configured table prefix" do
    template = File.read(template_path("create_wallets_tables.rb.erb"))

    assert_includes template, "Wallets.configuration.table_prefix"
    assert_includes template, "create_table wallets_table"
    assert_includes template, "add_index wallets_table"
    assert_equal 6, template.scan("t.bigint").size
    assert_includes template, "t.bigint :ledger_revision, null: false, default: 0"
    assert_includes template, 't.string :expiration_policy, null: false, default: "preserve"'
    assert_includes template, '"amount <> 0"'
    assert_includes template, '"from_wallet_id <> to_wallet_id"'
    refute_includes template, "outbound_transaction"
    refute_includes template, "inbound_transaction"
  end

  test "both migration templates create the same holds table" do
    [template_path("create_wallets_tables.rb.erb"), template_path("add_wallets_holds.rb.erb")].each do |path|
      template = File.read(path)
      holds_table = template[/create_table holds_table.*?\n    end\n/m]

      assert holds_table, "#{File.basename(path)} must create the holds table"
      assert_includes template, "def holds_table\n    \"\#{table_prefix}holds\"\n  end"
      assert_includes holds_table, "t.references :wallet, null: false"
      assert_includes holds_table, "foreign_key: { to_table: wallets_table }"
      assert_equal 2, holds_table.scan("foreign_key: { to_table: transactions_table }").size
      assert_includes holds_table, 'index: { unique: true, name: index_name("holds_on_capture_tx") }'
      assert_includes holds_table, "t.bigint :amount"
      assert_includes holds_table, "t.string :category, null: false"
      assert_includes holds_table, "t.datetime :releases_at"
      assert_includes holds_table, "t.datetime :released_at"
      assert_includes holds_table, "t.string :release_reason"
      assert_includes holds_table, "t.send(json_column_type, :metadata, null: false, default: json_column_default)"
      assert_includes holds_table, "t.send(json_column_type, :release_metadata, null: false, default: json_column_default)"
      assert_includes holds_table, 't.index [:wallet_id, :released_at], name: index_name("holds_on_wallet_and_released_at")'
      assert_includes holds_table, 't.index [:transaction_id, :released_at], name: index_name("holds_on_tx_and_released_at")'
      assert_includes holds_table, 't.index :releases_at, name: index_name("holds_on_releases_at")'
      assert_includes holds_table, '"amount IS NULL OR amount > 0"'
      assert_includes holds_table, '"transaction_id IS NULL OR amount IS NULL"'
      assert_includes holds_table, '"capture_transaction_id IS NULL OR " \\'
      assert_includes holds_table, '"(transaction_id IS NULL AND amount IS NOT NULL AND released_at IS NOT NULL)"'
      refute_includes holds_table, "where:", "no partial index may carry correctness (MySQL has none)"
    end
  end

  test "the upgrade template reads key types from the existing tables, not from generator settings" do
    template = File.read(template_path("add_wallets_holds.rb.erb"))

    assert_includes template, "class AddWalletsHolds < ActiveRecord::Migration<%= migration_version %>"
    assert_includes template, "return if table_exists?(holds_table)"
    assert_includes template, "connection.columns(table)"
    assert_includes template, "**key_type_of(wallets_table)"
    assert_equal 2, template.scan("**key_type_of(transactions_table)").size
    refute_includes template, "Rails.configuration.generators"
  end

  test "the dummy app's holds migration is the upgrade template, rendered" do
    # The dummy app is an existing 0.3 install, so every CI database runs the
    # real upgrade path. This keeps the two from drifting apart.
    rendered = ERB.new(File.read(template_path("add_wallets_holds.rb.erb")), trim_mode: "-")
      .result_with_hash(migration_version: "[7.2]")
    dummy_migration = Dir[File.expand_path("../dummy/db/migrate/*_add_wallets_holds.rb", __dir__)].sole

    assert_equal rendered, File.read(dummy_migration)
  end

  test "initializer template keeps optional categories and table prefix commented out" do
    template = File.read(template_path("initializer.rb"))

    assert_includes template, '# config.table_prefix = "wallets_"'
    assert_includes template, "# config.additional_categories = %w["
    refute_includes template, "\n  config.additional_categories = %w["
  end

  private

  def template_path(filename)
    File.expand_path("../../lib/generators/wallets/templates/#{filename}", __dir__)
  end
end
