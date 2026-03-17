# frozen_string_literal: true

require "rails/generators/base"
require "rails/generators/active_record"

module Wallets
  module Generators
    class InstallGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      def self.next_migration_number(dir)
        ActiveRecord::Generators::Base.next_migration_number(dir)
      end

      def create_migration_file
        migration_template "create_wallets_tables.rb.erb", File.join(db_migrate_path, "create_wallets_tables.rb")
      end

      def create_initializer
        template "initializer.rb", "config/initializers/wallets.rb"
      end

      def display_post_install_message
        say "\n🎉 The `wallets` gem has been installed.", :green
        say "\nTo complete the setup:"
        say "  1. Run 'rails db:migrate' to create the wallet tables."
        say "     ⚠️  If you want a custom table prefix, set config.table_prefix in config/initializers/wallets.rb before migrating.", :yellow
        say "  2. Add 'has_wallets' to any model that should own wallets."
        say "  3. Adjust config/initializers/wallets.rb for your default asset, categories, and callbacks."
        say "  4. Use owner.wallet(:asset_code) to start crediting, debiting, and transferring value."
        say "\nYou now have an append-only wallet ledger with balances, allocations, and transfers.\n", :green
      end

      private

      def migration_version
        "[#{ActiveRecord::VERSION::STRING.to_f}]"
      end
    end
  end
end
