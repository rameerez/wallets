# frozen_string_literal: true

require "wallets"

# Namespace for the wallets gem.
module Wallets
  # Compatibility require path for apps/gems that explicitly load
  # "wallets/railtie". The engine is the actual Rails integration point.
  Railtie = Engine unless const_defined?(:Railtie, false)
end
