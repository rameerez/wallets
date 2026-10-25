# frozen_string_literal: true

require "rails/generators/base"
require "rails/generators/active_record"

module Wallets
  module Generators
    # Brings an existing installation's schema up to date: the holds table
    # that 0.4 adds to 0.1, 0.2 and 0.3 installs, and the idempotency keys
    # that 0.5 adds to every earlier install.
    class UpgradeGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      def self.next_migration_number(dir)
        ActiveRecord::Generators::Base.next_migration_number(dir)
      end

      # Idempotent on purpose: a second run (even after a Rails upgrade has
      # changed the rendered migration version) points at the migration it
      # already wrote instead of adding a duplicate, and an app whose 0.4
      # schema is already complete (a fresh 0.4 install: the holds table and
      # the wallets' ledger revision) gets no migration at all, so it can
      # never hold a rollback that would drop them.
      def create_holds_migration
        existing_migration = self.class.migration_exists?(File.expand_path(db_migrate_path, destination_root), "add_wallets_holds")

        if existing_migration
          @pending = true
          say_status :exist, relative_to_original_destination_root(existing_migration), :blue
        elsif upgraded_schema?
          say_status :skip, "#{holds_table} already exists: there is nothing to migrate", :yellow
        else
          @pending = true
          migration_template "add_wallets_holds.rb.erb", File.join(db_migrate_path, "add_wallets_holds.rb")
        end
      end

      # Idempotent in the same way: written once, and only for a schema
      # whose transactions do not have their key yet.
      def create_idempotency_keys_migration
        existing_migration = self.class.migration_exists?(File.expand_path(db_migrate_path, destination_root), "add_wallets_idempotency_keys")

        if existing_migration
          @pending = true
          say_status :exist, relative_to_original_destination_root(existing_migration), :blue
        elsif keyed_schema?
          say_status :skip, "#{transactions_table} already has idempotency keys: there is nothing to migrate", :yellow
        else
          @pending = true
          migration_template "add_wallets_idempotency_keys.rb.erb", File.join(db_migrate_path, "add_wallets_idempotency_keys.rb")
        end
      end

      def display_post_upgrade_message
        unless @pending
          say "\n✅ This app already has the latest `wallets` schema: nothing to migrate.", :green
          say "\nRead the 0.4.0 CHANGELOG: `balance` is now the AVAILABLE balance, and held value is excluded from it."
          return
        end

        say "\n🎉 The `wallets` upgrade migrations are ready.", :green
        say "\nTo complete the upgrade:"
        say "  1. Run 'rails db:migrate' to add the holds table and the idempotency keys (each a no-op if already there)."
        say "  2. Read the 0.4.0 CHANGELOG: `balance` is now the AVAILABLE balance, and held value is excluded from it."
      end

      private

      # Asks the database when it can. One that does not exist yet, or cannot
      # be reached, gets the migration anyway: its `up` checks again.
      def upgraded_schema?
        ActiveRecord::Base.with_connection do |connection|
          connection.table_exists?(holds_table) && connection.column_exists?(wallets_table, :ledger_revision)
        end
      rescue ActiveRecord::ActiveRecordError
        false
      end

      # Same rule: a database that cannot be asked gets the migration.
      def keyed_schema?
        ActiveRecord::Base.with_connection do |connection|
          connection.column_exists?(transactions_table, :idempotency_key) &&
            (!connection.table_exists?(holds_table) || connection.column_exists?(holds_table, :idempotency_key))
        end
      rescue ActiveRecord::ActiveRecordError
        false
      end

      def holds_table
        "#{Wallets.configuration.table_prefix}holds"
      end

      def transactions_table
        "#{Wallets.configuration.table_prefix}transactions"
      end

      def wallets_table
        "#{Wallets.configuration.table_prefix}wallets"
      end

      def migration_version
        "[#{ActiveRecord::VERSION::STRING.to_f}]"
      end
    end
  end
end
