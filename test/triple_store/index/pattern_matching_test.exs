defmodule TripleStore.Index.PatternMatchingTest do
  @moduledoc """
  Tests for Task 1.4.4: Pattern Matching for Triple Index Layer.

  Verifies that:
  - All 8 triple patterns select the correct index
  - Prefix construction is correct for each pattern
  - The needs_filter flag is set appropriately
  - Pattern matching helper functions work correctly
  """

  use ExUnit.Case, async: true

  alias TripleStore.Index

  # ===========================================================================
  # select_index/1 - Index Selection
  # ===========================================================================

  describe "select_index/1 index selection" do
    test "SPO pattern selects :spo index" do
      result = Index.select_index({{:bound, 1}, {:bound, 2}, {:bound, 3}})
      assert result.index == :spo
    end

    test "SP? pattern selects :spo index" do
      result = Index.select_index({{:bound, 1}, {:bound, 2}, :var})
      assert result.index == :spo
    end

    test "S?? pattern selects :spo index" do
      result = Index.select_index({{:bound, 1}, :var, :var})
      assert result.index == :spo
    end

    test "?PO pattern selects :pos index" do
      result = Index.select_index({:var, {:bound, 2}, {:bound, 3}})
      assert result.index == :pos
    end

    test "?P? pattern selects :pos index" do
      result = Index.select_index({:var, {:bound, 2}, :var})
      assert result.index == :pos
    end

    test "??O pattern selects :osp index" do
      result = Index.select_index({:var, :var, {:bound, 3}})
      assert result.index == :osp
    end

    test "S?O pattern selects :osp index" do
      result = Index.select_index({{:bound, 1}, :var, {:bound, 3}})
      assert result.index == :osp
    end

    test "??? pattern selects :spo index for full scan" do
      result = Index.select_index({:var, :var, :var})
      assert result.index == :spo
    end
  end

  # ===========================================================================
  # select_index/1 - Prefix Construction
  # ===========================================================================

  describe "select_index/1 prefix construction" do
    test "SPO pattern builds full 24-byte key" do
      result = Index.select_index({{:bound, 1}, {:bound, 2}, {:bound, 3}})
      expected = Index.spo_key(1, 2, 3)
      assert result.prefix == expected
      assert byte_size(result.prefix) == 24
    end

    test "SP? pattern builds 16-byte S-P prefix" do
      result = Index.select_index({{:bound, 100}, {:bound, 200}, :var})
      expected = Index.spo_prefix(100, 200)
      assert result.prefix == expected
      assert byte_size(result.prefix) == 16
    end

    test "S?? pattern builds 8-byte S prefix" do
      result = Index.select_index({{:bound, 100}, :var, :var})
      expected = Index.spo_prefix(100)
      assert result.prefix == expected
      assert byte_size(result.prefix) == 8
    end

    test "?PO pattern builds 16-byte P-O prefix" do
      result = Index.select_index({:var, {:bound, 200}, {:bound, 300}})
      expected = Index.pos_prefix(200, 300)
      assert result.prefix == expected
      assert byte_size(result.prefix) == 16
    end

    test "?P? pattern builds 8-byte P prefix" do
      result = Index.select_index({:var, {:bound, 200}, :var})
      expected = Index.pos_prefix(200)
      assert result.prefix == expected
      assert byte_size(result.prefix) == 8
    end

    test "??O pattern builds 8-byte O prefix" do
      result = Index.select_index({:var, :var, {:bound, 300}})
      expected = Index.osp_prefix(300)
      assert result.prefix == expected
      assert byte_size(result.prefix) == 8
    end

    test "S?O pattern builds 16-byte O-S prefix" do
      result = Index.select_index({{:bound, 100}, :var, {:bound, 300}})
      expected = Index.osp_prefix(300, 100)
      assert result.prefix == expected
      assert byte_size(result.prefix) == 16
    end

    test "??? pattern builds empty prefix" do
      result = Index.select_index({:var, :var, :var})
      assert result.prefix == <<>>
      assert byte_size(result.prefix) == 0
    end
  end

  # ===========================================================================
  # select_index/1 - Filter Flags
  # ===========================================================================

  describe "select_index/1 filter flags" do
    test "SPO pattern does not need filter" do
      result = Index.select_index({{:bound, 1}, {:bound, 2}, {:bound, 3}})
      assert result.needs_filter == false
      assert result.filter_position == nil
    end

    test "SP? pattern does not need filter" do
      result = Index.select_index({{:bound, 1}, {:bound, 2}, :var})
      assert result.needs_filter == false
      assert result.filter_position == nil
    end

    test "S?? pattern does not need filter" do
      result = Index.select_index({{:bound, 1}, :var, :var})
      assert result.needs_filter == false
      assert result.filter_position == nil
    end

    test "?PO pattern does not need filter" do
      result = Index.select_index({:var, {:bound, 2}, {:bound, 3}})
      assert result.needs_filter == false
      assert result.filter_position == nil
    end

    test "?P? pattern does not need filter" do
      result = Index.select_index({:var, {:bound, 2}, :var})
      assert result.needs_filter == false
      assert result.filter_position == nil
    end

    test "??O pattern does not need filter" do
      result = Index.select_index({:var, :var, {:bound, 3}})
      assert result.needs_filter == false
      assert result.filter_position == nil
    end

    test "S?O pattern needs filter on predicate" do
      result = Index.select_index({{:bound, 1}, :var, {:bound, 3}})
      assert result.needs_filter == true
      assert result.filter_position == :predicate
    end

    test "??? pattern does not need filter" do
      result = Index.select_index({:var, :var, :var})
      assert result.needs_filter == false
      assert result.filter_position == nil
    end
  end

  # ===========================================================================
  # triple_matches_pattern?/2
  # ===========================================================================

  describe "triple_matches_pattern?/2" do
    test "matches when all bound values match" do
      pattern = {{:bound, 1}, {:bound, 2}, {:bound, 3}}
      assert Index.triple_matches_pattern?({1, 2, 3}, pattern) == true
    end

    test "does not match when subject differs" do
      pattern = {{:bound, 1}, {:bound, 2}, {:bound, 3}}
      assert Index.triple_matches_pattern?({9, 2, 3}, pattern) == false
    end

    test "does not match when predicate differs" do
      pattern = {{:bound, 1}, {:bound, 2}, {:bound, 3}}
      assert Index.triple_matches_pattern?({1, 9, 3}, pattern) == false
    end

    test "does not match when object differs" do
      pattern = {{:bound, 1}, {:bound, 2}, {:bound, 3}}
      assert Index.triple_matches_pattern?({1, 2, 9}, pattern) == false
    end

    test "matches any value for :var positions" do
      pattern = {{:bound, 1}, :var, {:bound, 3}}
      assert Index.triple_matches_pattern?({1, 999, 3}, pattern) == true
      assert Index.triple_matches_pattern?({1, 0, 3}, pattern) == true
      assert Index.triple_matches_pattern?({1, 12_345, 3}, pattern) == true
    end

    test "matches all triples for all-var pattern" do
      pattern = {:var, :var, :var}
      assert Index.triple_matches_pattern?({1, 2, 3}, pattern) == true
      assert Index.triple_matches_pattern?({0, 0, 0}, pattern) == true
      assert Index.triple_matches_pattern?({999, 888, 777}, pattern) == true
    end

    test "S?O pattern matches correctly" do
      pattern = {{:bound, 100}, :var, {:bound, 300}}
      assert Index.triple_matches_pattern?({100, 200, 300}, pattern) == true
      assert Index.triple_matches_pattern?({100, 999, 300}, pattern) == true
      assert Index.triple_matches_pattern?({101, 200, 300}, pattern) == false
      assert Index.triple_matches_pattern?({100, 200, 301}, pattern) == false
    end
  end

  # ===========================================================================
  # pattern_shape/1
  # ===========================================================================

  describe "pattern_shape/1" do
    test "returns shape for all-bound pattern" do
      assert Index.pattern_shape({{:bound, 1}, {:bound, 2}, {:bound, 3}}) ==
               {:bound, :bound, :bound}
    end

    test "returns shape for all-var pattern" do
      assert Index.pattern_shape({:var, :var, :var}) == {:var, :var, :var}
    end

    test "returns shape for mixed patterns" do
      assert Index.pattern_shape({{:bound, 1}, :var, :var}) == {:bound, :var, :var}
      assert Index.pattern_shape({:var, {:bound, 2}, :var}) == {:var, :bound, :var}
      assert Index.pattern_shape({:var, :var, {:bound, 3}}) == {:var, :var, :bound}
      assert Index.pattern_shape({{:bound, 1}, {:bound, 2}, :var}) == {:bound, :bound, :var}
      assert Index.pattern_shape({{:bound, 1}, :var, {:bound, 3}}) == {:bound, :var, :bound}
      assert Index.pattern_shape({:var, {:bound, 2}, {:bound, 3}}) == {:var, :bound, :bound}
    end

    test "shape is independent of bound values" do
      shape1 = Index.pattern_shape({{:bound, 1}, :var, {:bound, 3}})
      shape2 = Index.pattern_shape({{:bound, 999}, :var, {:bound, 888}})
      assert shape1 == shape2
    end
  end

  # ===========================================================================
  # Edge Cases
  # ===========================================================================

  describe "edge cases" do
    test "handles zero IDs" do
      result = Index.select_index({{:bound, 0}, {:bound, 0}, {:bound, 0}})
      assert result.index == :spo
      assert result.prefix == Index.spo_key(0, 0, 0)
    end

    test "handles large IDs" do
      import Bitwise
      max = (1 <<< 62) - 1

      result = Index.select_index({{:bound, max}, {:bound, max}, {:bound, max}})
      assert result.index == :spo
      assert result.prefix == Index.spo_key(max, max, max)
    end

    test "prefix bytes are in correct order for SPO" do
      result = Index.select_index({{:bound, 1}, {:bound, 2}, :var})
      # First 8 bytes should be subject (1), next 8 bytes should be predicate (2)
      <<s::64-big, p::64-big>> = result.prefix
      assert s == 1
      assert p == 2
    end

    test "prefix bytes are in correct order for POS" do
      result = Index.select_index({:var, {:bound, 2}, {:bound, 3}})
      # First 8 bytes should be predicate (2), next 8 bytes should be object (3)
      <<p::64-big, o::64-big>> = result.prefix
      assert p == 2
      assert o == 3
    end

    test "prefix bytes are in correct order for OSP" do
      result = Index.select_index({{:bound, 1}, :var, {:bound, 3}})
      # First 8 bytes should be object (3), next 8 bytes should be subject (1)
      <<o::64-big, s::64-big>> = result.prefix
      assert o == 3
      assert s == 1
    end
  end

  # ===========================================================================
  # Complete Pattern Coverage
  # ===========================================================================

  describe "complete pattern coverage" do
    @patterns [
      # All 8 possible patterns
      {{:bound, 1}, {:bound, 2}, {:bound, 3}},
      {{:bound, 1}, {:bound, 2}, :var},
      {{:bound, 1}, :var, :var},
      {:var, {:bound, 2}, {:bound, 3}},
      {:var, {:bound, 2}, :var},
      {:var, :var, {:bound, 3}},
      {{:bound, 1}, :var, {:bound, 3}},
      {:var, :var, :var}
    ]

    test "all patterns return valid index selection" do
      for pattern <- @patterns do
        result = Index.select_index(pattern)

        assert is_map(result)
        assert result.index in [:spo, :pos, :osp]
        assert is_binary(result.prefix)
        assert is_boolean(result.needs_filter)
        assert result.filter_position in [nil, :predicate]
      end
    end

    test "all patterns have consistent shape" do
      for pattern <- @patterns do
        shape = Index.pattern_shape(pattern)
        assert tuple_size(shape) == 3
        assert Enum.all?(Tuple.to_list(shape), &(&1 in [:bound, :var]))
      end
    end
  end
end
