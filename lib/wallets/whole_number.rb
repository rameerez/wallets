# frozen_string_literal: true

module Wallets
  # Canonical parser for values that enter integer ledger columns or influence
  # ledger decisions. Numeric strings are accepted only at serialization and
  # configuration boundaries when callers opt in explicitly.
  module WholeNumber
    module_function

    def parse(value, name:, allow_string: false)
      number = convert(value, allow_string: allow_string)

      return number unless number.nil?

      raise ArgumentError, "#{name} must be a whole number"
    end

    def convert(value, allow_string:)
      if value.is_a?(Integer)
        value
      elsif allow_string && value.is_a?(String)
        Integer(value, 10)
      elsif value.is_a?(Numeric) && finite?(value)
        integer = value.to_i
        integer if value == integer
      end
    rescue ArgumentError, TypeError, RangeError, NoMethodError
      nil
    end
    private_class_method :convert

    def finite?(value)
      !value.respond_to?(:finite?) || value.finite?
    end
    private_class_method :finite?
  end
end
