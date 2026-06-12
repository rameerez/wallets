# frozen_string_literal: true

require "rails"
require "active_record"
require "active_support/all"

require "wallets/version"
require "wallets/configuration"
require "wallets/callback_context"
require "wallets/callbacks"

module Wallets
  class ApplicationRecord < ActiveRecord::Base
    self.abstract_class = true
  end

  class Error < StandardError; end
  class InsufficientBalance < Error; end
  class InvalidTransfer < Error; end

  class << self
    attr_writer :configuration

    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield(configuration)
    end

    def reset!
      @configuration = nil
    end

    # Single source of truth for asset code normalization:
    # " EUR ", :EUR, and "eur" all name the same wallet.
    def normalize_asset_code(value)
      value.to_s.strip.downcase
    end
  end
end

require "wallets/models/concerns/embeddable"
require "wallets/models/concerns/has_metadata"
require "wallets/models/concerns/has_wallets"
require "wallets/models/wallet"
require "wallets/models/transaction"
require "wallets/models/allocation"
require "wallets/models/transfer"

require "wallets/engine"
