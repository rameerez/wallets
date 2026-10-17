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
      # already wrote instead of adding a duplicate, and an app whose holds
      # table already exists (a fresh 0.4 install) gets no migration at all,
      # so it can never hold a rollback that would drop that table.
      def create_holds_migration
        existing_migration = self.class.migration_exists?(File.expand_path(db_migrate_path, destination_root), "add_wallets_holds")

        if existing_migration
          say_status :exist, relative_to_original_destination_root(existing_migration), :blue
        elsif holds_table_exists?
          @skipped = true
          say_status :skip, "#{holds_table} already exists: there is nothing to migrate", :yellow
        else
          migration_template "add_wallets_holds.rb.erb", File.join(db_migrate_path, "add_wallets_holds.rb")
        end
      end

      def display_post_upgrade_message
        if @skipped
          say "\n✅ This app already has the `wallets` 0.4 holds table: nothing to migrate.", :green
          say "\nRead the 0.4.0 CHANGELOG: `balance` is now the AVAILABLE balance, and held value is excluded from it."
          return
        end

        say "\n🎉 The `wallets` upgrade migration is ready.", :green
        say "\nTo complete the upgrade:"
        say "  1. Run 'rails db:migrate' to add the holds table (a no-op if it already exists)."
        say "  2. Read the 0.4.0 CHANGELOG: `balance` is now the AVAILABLE balance, and held value is excluded from it."
      end

      private

      # Asks the database when it can. One that does not exist yet, or cannot
      # be reached, gets the migration anyway: its `up` checks again.
      def holds_table_exists?
        ActiveRecord::Base.with_connection { |connection| connection.table_exists?(holds_table) }
      rescue ActiveRecord::ActiveRecordError
        false
      end

      def holds_table
        "#{Wallets.configuration.table_prefix}holds"
      end

      def migration_version
        "[#{ActiveRecord::VERSION::STRING.to_f}]"
      end
    end
  end
end
