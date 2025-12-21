defmodule TripleStore.Dictionary.TermIdEncodingTest do
  @moduledoc """
  Tests for Term ID encoding/decoding (Task 1.3.1).

  Covers:
  - Type tag encoding/decoding roundtrip
  - Edge cases for 60-bit values
  - Type extraction functions
  """
  use ExUnit.Case, async: true

  import Bitwise

  alias TripleStore.Dictionary

  describe "encode_id/2" do
    test "encodes URI type with sequence" do
      id = Dictionary.encode_id(Dictionary.type_uri(), 42)
      assert id == (1 <<< 60) + 42
    end

    test "encodes BNode type with sequence" do
      id = Dictionary.encode_id(Dictionary.type_bnode(), 100)
      assert id == (2 <<< 60) + 100
    end

    test "encodes Literal type with sequence" do
      id = Dictionary.encode_id(Dictionary.type_literal(), 999)
      assert id == (3 <<< 60) + 999
    end

    test "encodes Integer type with value" do
      id = Dictionary.encode_id(Dictionary.type_integer(), 12_345)
      assert id == (4 <<< 60) + 12_345
    end

    test "encodes Decimal type with value" do
      id = Dictionary.encode_id(Dictionary.type_decimal(), 67_890)
      assert id == (5 <<< 60) + 67_890
    end

    test "encodes DateTime type with value" do
      id = Dictionary.encode_id(Dictionary.type_datetime(), 1_705_000_000_000)
      assert id == (6 <<< 60) + 1_705_000_000_000
    end

    test "encodes zero sequence" do
      id = Dictionary.encode_id(Dictionary.type_uri(), 0)
      assert id == 1 <<< 60
    end

    test "encodes maximum sequence value" do
      max_seq = Dictionary.max_sequence()
      id = Dictionary.encode_id(Dictionary.type_uri(), max_seq)
      {type, value} = Dictionary.decode_id(id)
      assert type == :uri
      assert value == max_seq
    end
  end

  describe "decode_id/1" do
    test "decodes URI type correctly" do
      id = Dictionary.encode_id(Dictionary.type_uri(), 42)
      assert Dictionary.decode_id(id) == {:uri, 42}
    end

    test "decodes BNode type correctly" do
      id = Dictionary.encode_id(Dictionary.type_bnode(), 100)
      assert Dictionary.decode_id(id) == {:bnode, 100}
    end

    test "decodes Literal type correctly" do
      id = Dictionary.encode_id(Dictionary.type_literal(), 999)
      assert Dictionary.decode_id(id) == {:literal, 999}
    end

    test "decodes Integer type correctly" do
      id = Dictionary.encode_id(Dictionary.type_integer(), 12_345)
      assert Dictionary.decode_id(id) == {:integer, 12_345}
    end

    test "decodes Decimal type correctly" do
      id = Dictionary.encode_id(Dictionary.type_decimal(), 67_890)
      assert Dictionary.decode_id(id) == {:decimal, 67_890}
    end

    test "decodes DateTime type correctly" do
      id = Dictionary.encode_id(Dictionary.type_datetime(), 1_705_000_000_000)
      assert Dictionary.decode_id(id) == {:datetime, 1_705_000_000_000}
    end

    test "returns unknown for unrecognized type tag" do
      # Type tag 0 is not defined
      id = 0 <<< 60 ||| 42
      assert Dictionary.decode_id(id) == {:unknown, 42}
    end

    test "returns unknown for type tag 7" do
      id = 7 <<< 60 ||| 42
      assert Dictionary.decode_id(id) == {:unknown, 42}
    end

    test "roundtrip preserves all bits for large values" do
      large_value = (1 <<< 59) - 1
      id = Dictionary.encode_id(Dictionary.type_uri(), large_value)
      {type, value} = Dictionary.decode_id(id)
      assert type == :uri
      assert value == large_value
    end
  end

  describe "term_type/1" do
    test "extracts URI type" do
      id = Dictionary.encode_id(Dictionary.type_uri(), 42)
      assert Dictionary.term_type(id) == :uri
    end

    test "extracts BNode type" do
      id = Dictionary.encode_id(Dictionary.type_bnode(), 42)
      assert Dictionary.term_type(id) == :bnode
    end

    test "extracts Literal type" do
      id = Dictionary.encode_id(Dictionary.type_literal(), 42)
      assert Dictionary.term_type(id) == :literal
    end

    test "extracts Integer type" do
      id = Dictionary.encode_id(Dictionary.type_integer(), 42)
      assert Dictionary.term_type(id) == :integer
    end

    test "extracts Decimal type" do
      id = Dictionary.encode_id(Dictionary.type_decimal(), 42)
      assert Dictionary.term_type(id) == :decimal
    end

    test "extracts DateTime type" do
      id = Dictionary.encode_id(Dictionary.type_datetime(), 42)
      assert Dictionary.term_type(id) == :datetime
    end

    test "returns unknown for invalid type tag" do
      id = 15 <<< 60 ||| 42
      assert Dictionary.term_type(id) == :unknown
    end
  end

  describe "inline_encoded?/1" do
    test "returns false for URI" do
      id = Dictionary.encode_id(Dictionary.type_uri(), 42)
      refute Dictionary.inline_encoded?(id)
    end

    test "returns false for BNode" do
      id = Dictionary.encode_id(Dictionary.type_bnode(), 42)
      refute Dictionary.inline_encoded?(id)
    end

    test "returns false for Literal" do
      id = Dictionary.encode_id(Dictionary.type_literal(), 42)
      refute Dictionary.inline_encoded?(id)
    end

    test "returns true for Integer" do
      id = Dictionary.encode_id(Dictionary.type_integer(), 42)
      assert Dictionary.inline_encoded?(id)
    end

    test "returns true for Decimal" do
      id = Dictionary.encode_id(Dictionary.type_decimal(), 42)
      assert Dictionary.inline_encoded?(id)
    end

    test "returns true for DateTime" do
      id = Dictionary.encode_id(Dictionary.type_datetime(), 42)
      assert Dictionary.inline_encoded?(id)
    end
  end

  describe "dictionary_allocated?/1" do
    test "returns true for URI" do
      id = Dictionary.encode_id(Dictionary.type_uri(), 42)
      assert Dictionary.dictionary_allocated?(id)
    end

    test "returns true for BNode" do
      id = Dictionary.encode_id(Dictionary.type_bnode(), 42)
      assert Dictionary.dictionary_allocated?(id)
    end

    test "returns true for Literal" do
      id = Dictionary.encode_id(Dictionary.type_literal(), 42)
      assert Dictionary.dictionary_allocated?(id)
    end

    test "returns false for Integer" do
      id = Dictionary.encode_id(Dictionary.type_integer(), 42)
      refute Dictionary.dictionary_allocated?(id)
    end

    test "returns false for Decimal" do
      id = Dictionary.encode_id(Dictionary.type_decimal(), 42)
      refute Dictionary.dictionary_allocated?(id)
    end

    test "returns false for DateTime" do
      id = Dictionary.encode_id(Dictionary.type_datetime(), 42)
      refute Dictionary.dictionary_allocated?(id)
    end
  end

  describe "encoding roundtrip" do
    test "all types roundtrip correctly" do
      types = [
        {Dictionary.type_uri(), :uri},
        {Dictionary.type_bnode(), :bnode},
        {Dictionary.type_literal(), :literal},
        {Dictionary.type_integer(), :integer},
        {Dictionary.type_decimal(), :decimal},
        {Dictionary.type_datetime(), :datetime}
      ]

      for {type_tag, expected_type} <- types do
        for value <- [0, 1, 42, 1000, 1_000_000, Dictionary.max_sequence()] do
          id = Dictionary.encode_id(type_tag, value)
          {decoded_type, decoded_value} = Dictionary.decode_id(id)
          assert decoded_type == expected_type
          assert decoded_value == value
        end
      end
    end
  end

  describe "type tag constants" do
    test "type tags have expected values" do
      assert Dictionary.type_uri() == 1
      assert Dictionary.type_bnode() == 2
      assert Dictionary.type_literal() == 3
      assert Dictionary.type_integer() == 4
      assert Dictionary.type_decimal() == 5
      assert Dictionary.type_datetime() == 6
    end

    test "type tags fit in 4 bits" do
      assert Dictionary.type_uri() < 16
      assert Dictionary.type_bnode() < 16
      assert Dictionary.type_literal() < 16
      assert Dictionary.type_integer() < 16
      assert Dictionary.type_decimal() < 16
      assert Dictionary.type_datetime() < 16
    end
  end

  describe "configuration constants" do
    test "max_sequence is 2^59 - 1" do
      assert Dictionary.max_sequence() == (1 <<< 59) - 1
    end

    test "flush_interval is 1000" do
      assert Dictionary.flush_interval() == 1000
    end

    test "safety_margin is 1000" do
      assert Dictionary.safety_margin() == 1000
    end

    test "max_term_size is 16KB" do
      assert Dictionary.max_term_size() == 16_384
    end
  end
end
