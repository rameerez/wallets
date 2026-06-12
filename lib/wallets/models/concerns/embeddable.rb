# frozen_string_literal: true

module Wallets
  # Lets other gems (like usage_credits) subclass the ledger models with their
  # own tables, configuration, and callbacks without touching global Wallets
  # state in the same application.
  #
  # The embedding contract on a subclass:
  #
  #   self.embedded_table_name = "usage_credits_wallets"      # exact table name
  #   self.config_provider = -> { UsageCredits.configuration } # custom config
  #
  # When `embedded_table_name` is not set, the table name is derived from the
  # provided config's `table_prefix` plus the model's `table_suffix`
  # ("wallets", "transactions", "allocations", or "transfers").
  module Embeddable
    extend ActiveSupport::Concern

    included do
      class_attribute :embedded_table_name, default: nil
      class_attribute :config_provider, default: -> { Wallets.configuration }
      class_attribute :table_suffix, default: nil, instance_accessor: false
    end

    class_methods do
      def table_name
        embedded_table_name || "#{resolved_config.table_prefix}#{table_suffix}"
      end

      def resolved_config
        value = config_provider
        value.respond_to?(:call) ? value.call : value
      end
    end
  end
end
