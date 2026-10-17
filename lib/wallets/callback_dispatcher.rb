# frozen_string_literal: true

module Wallets
  # Shared callback execution plumbing for wallets and embedding gems.
  # Extenders provide callback_configuration, callback_context_class, and
  # callback_log_prefix; arity handling, freezing, and error isolation live in
  # one place.
  module CallbackDispatcher
    def dispatch(event, **context_data)
      reader = :"on_#{event}_callback"
      config = callback_configuration
      return unless config.respond_to?(reader)

      callback = config.public_send(reader)
      return unless callback.is_a?(Proc)

      context = callback_context_class.new(event: event, **context_data).freeze
      execute_safely(callback, context)
    end

    def execute_safely(callback, context)
      case callback.arity
      when 1, -1, -2
        callback.call(context)
      when 0
        callback.call
      else
        log_warn "#{callback_log_prefix} Callback has unexpected arity (#{callback.arity}). Expected 0 or 1."
      end
    rescue => e
      log_error "#{callback_log_prefix} Callback error for #{context.event}: #{e.class}: #{e.message}"
      log_debug Array(e.backtrace).join("\n")
    end

    def log_error(message)
      rails_logger ? rails_logger.error(message) : warn(message)
    end

    def log_warn(message)
      rails_logger ? rails_logger.warn(message) : warn(message)
    end

    def log_debug(message)
      rails_logger.debug(message) if rails_logger&.debug?
    end

    def rails_logger
      Rails.logger if defined?(Rails) && Rails.respond_to?(:logger)
    end
  end
end
