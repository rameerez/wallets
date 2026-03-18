# frozen_string_literal: true

module Wallets
  # Configuration for the Wallets gem. This is the single source of truth for
  # the wallet owner API, ledger callbacks, and installation-time table names.
  class Configuration
    # =========================================
    # Basic Settings
    # =========================================

    attr_accessor :allow_negative_balance
    attr_reader :default_asset, :additional_categories, :table_prefix
    attr_reader :low_balance_threshold
    attr_reader :transfer_expiration_policy

    # =========================================
    # Lifecycle Callbacks
    # =========================================

    attr_reader :on_balance_credited_callback,
                :on_balance_debited_callback,
                :on_transfer_completed_callback,
                :on_low_balance_reached_callback,
                :on_balance_depleted_callback,
                :on_insufficient_balance_callback

    def initialize
      # Keep the out-of-the-box default close to the most common "main wallet"
      # use case while still allowing apps to override it immediately.
      @default_asset = :credits
      @additional_categories = []
      @allow_negative_balance = false
      @low_balance_threshold = nil
      @transfer_expiration_policy = :preserve
      # This prefix is used by the models at runtime and by the install
      # migration when it is executed for the first time.
      @table_prefix = "wallets_"

      @on_balance_credited_callback = nil
      @on_balance_debited_callback = nil
      @on_transfer_completed_callback = nil
      @on_low_balance_reached_callback = nil
      @on_balance_depleted_callback = nil
      @on_insufficient_balance_callback = nil
    end

    def default_asset=(value)
      value = normalize_asset_code(value)
      raise ArgumentError, "Default asset can't be blank" if value.blank?

      @default_asset = value.to_sym
    end

    def additional_categories=(categories)
      raise ArgumentError, "Additional categories must be an array" unless categories.is_a?(Array)

      @additional_categories = categories.map { |category| normalize_category(category) }.reject(&:blank?).uniq
    end

    def low_balance_threshold=(value)
      if value
        value = Integer(value)
        raise ArgumentError, "Low balance threshold must be greater than or equal to zero" if value.negative?
      end

      @low_balance_threshold = value
    end

    def table_prefix=(value)
      value = value.to_s
      raise ArgumentError, "Table prefix can't be blank" if value.blank?

      @table_prefix = value
    end

    def transfer_expiration_policy=(value)
      normalized_value = value.to_s.strip.downcase.to_sym
      allowed_values = %i[preserve none]

      raise ArgumentError, "Transfer expiration policy must be one of: #{allowed_values.join(', ')}" unless allowed_values.include?(normalized_value)

      @transfer_expiration_policy = normalized_value
    end

    def on_balance_credited(&block)
      @on_balance_credited_callback = block
    end

    def on_balance_debited(&block)
      @on_balance_debited_callback = block
    end

    def on_transfer_completed(&block)
      @on_transfer_completed_callback = block
    end

    def on_low_balance_reached(&block)
      @on_low_balance_reached_callback = block
    end

    def on_balance_depleted(&block)
      @on_balance_depleted_callback = block
    end

    def on_insufficient_balance(&block)
      @on_insufficient_balance_callback = block
    end

    private

    def normalize_asset_code(value)
      value.to_s.strip.downcase
    end

    def normalize_category(value)
      value.to_s.strip
    end
  end
end
