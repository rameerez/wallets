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
  end
end

require "wallets/models/concerns/has_wallets"
require "wallets/models/wallet"
require "wallets/models/transaction"
require "wallets/models/allocation"
require "wallets/models/transfer"

require "wallets/engine" if defined?(Rails)
require "wallets/railtie" if defined?(Rails)
