# frozen_string_literal: true

require "test_helper"

class Wallets::InstallTemplatesTest < ActiveSupport::TestCase
  test "migration template uses the configured table prefix" do
    template = File.read(template_path("create_wallets_tables.rb.erb"))

    assert_includes template, "Wallets.configuration.table_prefix"
    assert_includes template, "create_table wallets_table"
    assert_includes template, "add_index wallets_table"
    assert_equal 4, template.scan("t.bigint").size
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
