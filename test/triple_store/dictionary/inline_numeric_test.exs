defmodule TripleStore.Dictionary.InlineNumericTest do
  @moduledoc """
  Tests for inline numeric encoding/decoding (Task 1.3.5).

  Covers:
  - Integer encoding/decoding with two's complement
  - Decimal encoding/decoding with custom format
  - DateTime encoding/decoding with millisecond precision
  - Edge cases and precision guarantees
  """
  use ExUnit.Case, async: true

  import Bitwise

  alias TripleStore.Dictionary

  describe "inline_encodable_integer?/1" do
    test "returns true for zero" do
      assert Dictionary.inline_encodable_integer?(0)
    end

    test "returns true for positive integers in range" do
      assert Dictionary.inline_encodable_integer?(1)
      assert Dictionary.inline_encodable_integer?(42)
      assert Dictionary.inline_encodable_integer?(1_000_000)
      assert Dictionary.inline_encodable_integer?(Dictionary.max_inline_integer())
    end

    test "returns true for negative integers in range" do
      assert Dictionary.inline_encodable_integer?(-1)
      assert Dictionary.inline_encodable_integer?(-42)
      assert Dictionary.inline_encodable_integer?(-1_000_000)
      assert Dictionary.inline_encodable_integer?(Dictionary.min_inline_integer())
    end

    test "returns false for integers above range" do
      refute Dictionary.inline_encodable_integer?(Dictionary.max_inline_integer() + 1)
    end

    test "returns false for integers below range" do
      refute Dictionary.inline_encodable_integer?(Dictionary.min_inline_integer() - 1)
    end
  end

  describe "encode_integer/1" do
    test "encodes zero" do
      assert {:ok, id} = Dictionary.encode_integer(0)
      assert Dictionary.term_type(id) == :integer
    end

    test "encodes positive integers" do
      assert {:ok, id} = Dictionary.encode_integer(42)
      assert Dictionary.term_type(id) == :integer
    end

    test "encodes negative integers" do
      assert {:ok, id} = Dictionary.encode_integer(-42)
      assert Dictionary.term_type(id) == :integer
    end

    test "encodes maximum positive value" do
      max = Dictionary.max_inline_integer()
      assert {:ok, id} = Dictionary.encode_integer(max)
      assert Dictionary.term_type(id) == :integer
    end

    test "encodes minimum negative value" do
      min = Dictionary.min_inline_integer()
      assert {:ok, id} = Dictionary.encode_integer(min)
      assert Dictionary.term_type(id) == :integer
    end

    test "returns error for out of range positive" do
      assert {:error, :out_of_range} =
               Dictionary.encode_integer(Dictionary.max_inline_integer() + 1)
    end

    test "returns error for out of range negative" do
      assert {:error, :out_of_range} =
               Dictionary.encode_integer(Dictionary.min_inline_integer() - 1)
    end
  end

  describe "decode_integer/1" do
    test "decodes zero" do
      {:ok, id} = Dictionary.encode_integer(0)
      assert {:ok, 0} = Dictionary.decode_integer(id)
    end

    test "decodes positive integers" do
      for value <- [1, 42, 100, 1000, 1_000_000] do
        {:ok, id} = Dictionary.encode_integer(value)
        assert {:ok, ^value} = Dictionary.decode_integer(id)
      end
    end

    test "decodes negative integers" do
      for value <- [-1, -42, -100, -1000, -1_000_000] do
        {:ok, id} = Dictionary.encode_integer(value)
        assert {:ok, ^value} = Dictionary.decode_integer(id)
      end
    end

    test "decodes maximum positive value" do
      max = Dictionary.max_inline_integer()
      {:ok, id} = Dictionary.encode_integer(max)
      assert {:ok, ^max} = Dictionary.decode_integer(id)
    end

    test "decodes minimum negative value" do
      min = Dictionary.min_inline_integer()
      {:ok, id} = Dictionary.encode_integer(min)
      assert {:ok, ^min} = Dictionary.decode_integer(id)
    end

    test "returns error for non-integer type" do
      uri_id = Dictionary.encode_id(Dictionary.type_uri(), 42)
      assert {:error, :not_an_integer} = Dictionary.decode_integer(uri_id)
    end
  end

  describe "integer encoding roundtrip" do
    test "roundtrip preserves value for various integers" do
      test_values = [
        0,
        1,
        -1,
        42,
        -42,
        127,
        -128,
        255,
        -256,
        1000,
        -1000,
        1_000_000,
        -1_000_000,
        1_000_000_000,
        -1_000_000_000,
        Dictionary.max_inline_integer(),
        Dictionary.min_inline_integer()
      ]

      for value <- test_values do
        {:ok, id} = Dictionary.encode_integer(value)
        {:ok, decoded} = Dictionary.decode_integer(id)
        assert decoded == value, "Failed for value: #{value}"
      end
    end
  end

  describe "inline_encodable_datetime?/1" do
    test "returns true for current time" do
      dt = DateTime.utc_now()
      assert Dictionary.inline_encodable_datetime?(dt)
    end

    test "returns true for Unix epoch" do
      {:ok, dt} = DateTime.new(~D[1970-01-01], ~T[00:00:00], "Etc/UTC")
      assert Dictionary.inline_encodable_datetime?(dt)
    end

    test "returns true for far future date" do
      {:ok, dt} = DateTime.new(~D[3000-01-01], ~T[00:00:00], "Etc/UTC")
      assert Dictionary.inline_encodable_datetime?(dt)
    end

    test "returns false for date before 1970" do
      {:ok, dt} = DateTime.new(~D[1969-12-31], ~T[23:59:59], "Etc/UTC")
      refute Dictionary.inline_encodable_datetime?(dt)
    end
  end

  describe "encode_datetime/1" do
    test "encodes current time" do
      dt = DateTime.utc_now()
      assert {:ok, id} = Dictionary.encode_datetime(dt)
      assert Dictionary.term_type(id) == :datetime
    end

    test "encodes Unix epoch" do
      {:ok, dt} = DateTime.new(~D[1970-01-01], ~T[00:00:00], "Etc/UTC")
      assert {:ok, id} = Dictionary.encode_datetime(dt)
      assert Dictionary.term_type(id) == :datetime
    end

    test "returns error for date before 1970" do
      {:ok, dt} = DateTime.new(~D[1969-12-31], ~T[23:59:59], "Etc/UTC")
      assert {:error, :out_of_range} = Dictionary.encode_datetime(dt)
    end
  end

  describe "decode_datetime/1" do
    test "decodes to DateTime struct" do
      dt = DateTime.utc_now()
      {:ok, id} = Dictionary.encode_datetime(dt)
      assert {:ok, %DateTime{}} = Dictionary.decode_datetime(id)
    end

    test "preserves millisecond precision" do
      {:ok, dt} = DateTime.new(~D[2024-01-15], ~T[10:30:45.123], "Etc/UTC")
      {:ok, id} = Dictionary.encode_datetime(dt)
      {:ok, decoded} = Dictionary.decode_datetime(id)

      assert DateTime.to_unix(decoded, :millisecond) == DateTime.to_unix(dt, :millisecond)
    end

    test "returns error for non-datetime type" do
      uri_id = Dictionary.encode_id(Dictionary.type_uri(), 42)
      assert {:error, :not_a_datetime} = Dictionary.decode_datetime(uri_id)
    end
  end

  describe "datetime encoding roundtrip" do
    test "roundtrip preserves value (to millisecond precision)" do
      test_dates = [
        ~U[1970-01-01 00:00:00.000Z],
        ~U[2000-01-01 12:00:00.000Z],
        ~U[2024-01-15 10:30:45.123Z],
        DateTime.utc_now()
      ]

      for dt <- test_dates do
        {:ok, id} = Dictionary.encode_datetime(dt)
        {:ok, decoded} = Dictionary.decode_datetime(id)

        # Compare at millisecond precision
        assert DateTime.to_unix(decoded, :millisecond) == DateTime.to_unix(dt, :millisecond)
      end
    end
  end

  describe "encode_decimal/1" do
    test "encodes zero" do
      decimal = Decimal.new(0)
      assert {:ok, id} = Dictionary.encode_decimal(decimal)
      assert Dictionary.term_type(id) == :decimal
    end

    test "encodes positive integers" do
      decimal = Decimal.new(42)
      assert {:ok, id} = Dictionary.encode_decimal(decimal)
      assert Dictionary.term_type(id) == :decimal
    end

    test "encodes negative integers" do
      decimal = Decimal.new(-42)
      assert {:ok, id} = Dictionary.encode_decimal(decimal)
      assert Dictionary.term_type(id) == :decimal
    end

    test "encodes decimal fractions" do
      decimal = Decimal.new("3.14159")
      assert {:ok, id} = Dictionary.encode_decimal(decimal)
      assert Dictionary.term_type(id) == :decimal
    end

    test "returns error for very large coefficient" do
      # Coefficient larger than 48 bits
      large_coef = 1 <<< 49
      decimal = %Decimal{sign: 1, coef: large_coef, exp: 0}
      assert {:error, :out_of_range} = Dictionary.encode_decimal(decimal)
    end
  end

  describe "decode_decimal/1" do
    test "decodes zero" do
      decimal = Decimal.new(0)
      {:ok, id} = Dictionary.encode_decimal(decimal)
      {:ok, decoded} = Dictionary.decode_decimal(id)
      assert Decimal.eq?(decoded, Decimal.new(0))
    end

    test "decodes positive integers" do
      decimal = Decimal.new(42)
      {:ok, id} = Dictionary.encode_decimal(decimal)
      {:ok, decoded} = Dictionary.decode_decimal(id)
      assert Decimal.eq?(decoded, decimal)
    end

    test "decodes negative integers" do
      decimal = Decimal.new(-42)
      {:ok, id} = Dictionary.encode_decimal(decimal)
      {:ok, decoded} = Dictionary.decode_decimal(id)
      assert Decimal.eq?(decoded, decimal)
    end

    test "returns error for non-decimal type" do
      uri_id = Dictionary.encode_id(Dictionary.type_uri(), 42)
      assert {:error, :not_a_decimal} = Dictionary.decode_decimal(uri_id)
    end
  end

  describe "decimal encoding roundtrip" do
    test "roundtrip preserves value for integers" do
      test_values = [0, 1, -1, 42, -42, 1000, -1000, 1_000_000]

      for value <- test_values do
        decimal = Decimal.new(value)
        {:ok, id} = Dictionary.encode_decimal(decimal)
        {:ok, decoded} = Dictionary.decode_decimal(id)
        assert Decimal.eq?(decoded, decimal), "Failed for value: #{value}"
      end
    end

    test "roundtrip preserves value for simple fractions" do
      test_values = ["0.5", "-0.5", "1.5", "-1.5", "0.25", "0.125"]

      for value <- test_values do
        decimal = Decimal.new(value)
        {:ok, id} = Dictionary.encode_decimal(decimal)
        {:ok, decoded} = Dictionary.decode_decimal(id)
        assert Decimal.eq?(decoded, decimal), "Failed for value: #{value}"
      end
    end
  end

  describe "inline encoding constants" do
    test "max_inline_integer is 2^59 - 1" do
      assert Dictionary.max_inline_integer() == (1 <<< 59) - 1
    end

    test "min_inline_integer is -2^59" do
      assert Dictionary.min_inline_integer() == -(1 <<< 59)
    end

    test "integer range is symmetric around zero (almost)" do
      # Two's complement: one more negative value than positive
      assert abs(Dictionary.min_inline_integer()) == Dictionary.max_inline_integer() + 1
    end
  end
end
