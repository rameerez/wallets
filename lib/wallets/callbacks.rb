# frozen_string_literal: true

module Wallets
  # Centralized callback dispatcher with error isolation.
  # Callback failures should never break the ledger write that triggered them.
  module Callbacks
    module_function

    def dispatch(event, **context_data)
      reader = :"on_#{event}_callback"
      return unless Wallets.configuration.respond_to?(reader)

      callback = Wallets.configuration.public_send(reader)
      return unless callback.is_a?(Proc)

      context = CallbackContext.new(event: event, **context_data)
      execute_safely(callback, context)
    end

    def execute_safely(callback, context)
      case callback.arity
      when 1, -1, -2
        callback.call(context)
      when 0
        callback.call
      else
        log_warn "[Wallets] Callback has unexpected arity (#{callback.arity}). Expected 0 or 1."
      end
    rescue StandardError => e
      log_error "[Wallets] Callback error for #{context.event}: #{e.class}: #{e.message}"
      log_debug e.backtrace.join("\n")
    end

    def log_error(message)
      if rails_logger
        rails_logger.error(message)
      else
        warn message
      end
    end

    def log_warn(message)
      if rails_logger
        rails_logger.warn(message)
      else
        warn message
      end
    end

    def log_debug(message)
      rails_logger.debug(message) if rails_logger&.debug?
    end

    def rails_logger
      Rails.logger if defined?(Rails) && Rails.respond_to?(:logger)
    end
  end
end
