# frozen_string_literal: true

require "rails/generators/base"
require "rails/generators/active_record"

module Wallets
  module Generators
    # Brings an existing installation's schema up to date. Today that is one
    # migration: the holds table that 0.4 adds to 0.1, 0.2 and 0.3 installs.
    class UpgradeGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      def self.next_migration_number(dir)
        ActiveRecord::Generators::Base.next_migration_number(dir)
      end

      # Idempotent on purpose: a second run (even after a Rails upgrade has
      # changed the rendered migration version) points at the migration it
      # already wrote instead of adding a duplicate.
      def create_holds_migration
        existing_migration = self.class.migration_exists?(File.expand_path(db_migrate_path, destination_root), "add_wallets_holds")

        if existing_migration
          say_status :exist, relative_to_original_destination_root(existing_migration), :blue
        else
          migration_template "add_wallets_holds.rb.erb", File.join(db_migrate_path, "add_wallets_holds.rb")
        end
      end

      def display_post_upgrade_message
        say "\n🎉 The `wallets` upgrade migration is ready.", :green
        say "\nTo complete the upgrade:"
        say "  1. Run 'rails db:migrate' to add the holds table (a no-op if it already exists)."
        say "  2. Read the 0.4.0 CHANGELOG: `balance` is now the AVAILABLE balance, and held value is excluded from it."
      end

      private

      def migration_version
        "[#{ActiveRecord::VERSION::STRING.to_f}]"
      end
    end
  end
end
