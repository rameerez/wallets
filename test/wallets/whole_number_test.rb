# frozen_string_literal: true

require "test_helper"
require "bigdecimal"

class WholeNumberTest < ActiveSupport::TestCase
  test "accepts finite whole numeric values" do
    assert_equal 12, Wallets::WholeNumber.parse(12, name: "Value")
    assert_equal 12, Wallets::WholeNumber.parse(12.0, name: "Value")
    assert_equal 12, Wallets::WholeNumber.parse(Rational(24, 2), name: "Value")
    assert_equal 12, Wallets::WholeNumber.parse(BigDecimal("12.0"), name: "Value")
  end

  test "accepts integer strings only when explicitly enabled" do
    assert_equal(-12, Wallets::WholeNumber.parse("-12", name: "Value", allow_string: true))

    error = assert_raises(ArgumentError) do
      Wallets::WholeNumber.parse("12", name: "Value")
    end
    assert_equal "Value must be a whole number", error.message
  end

  test "rejects ambiguous or non-finite values with one stable error" do
    invalid_values = [nil, :twelve, "12.0", 12.5, Float::INFINITY, Float::NAN, Complex(12, 1)]

    invalid_values.each do |value|
      error = assert_raises(ArgumentError) do
        Wallets::WholeNumber.parse(value, name: "Value", allow_string: true)
      end
      assert_equal "Value must be a whole number", error.message
    end
  end
end
