defmodule TripleStore.Dictionary.ConcurrentAccessTest do
  @moduledoc """
  Tests for concurrent access patterns (Concern C5).

  Covers:
  - Parallel ID encoding operations
  - No race conditions in pure functions
  - Thread safety of inline encoding

  Note: Full concurrent get_or_create_id tests will be added when
  the GenServer implementation is complete (Task 1.3.3).
  """
  use ExUnit.Case, async: true

  alias TripleStore.Dictionary

  describe "concurrent encode_id/2" do
    test "parallel encode_id operations produce unique IDs" do
      # Spawn many tasks that encode IDs concurrently
      tasks =
        for i <- 1..100 do
          Task.async(fn ->
            Dictionary.encode_id(Dictionary.type_uri(), i)
          end)
        end

      ids = Task.await_many(tasks)

      # All IDs should be unique
      assert length(Enum.uniq(ids)) == 100
    end

    test "parallel decode_id operations are consistent" do
      # Create IDs first
      ids = for i <- 1..100, do: Dictionary.encode_id(Dictionary.type_uri(), i)

      # Decode them in parallel
      tasks =
        for id <- ids do
          Task.async(fn ->
            Dictionary.decode_id(id)
          end)
        end

      results = Task.await_many(tasks)

      # All results should be valid URI types with correct values
      for {{type, value}, i} <- Enum.with_index(results, 1) do
        assert type == :uri
        assert value == i
      end
    end
  end

  describe "concurrent inline integer encoding" do
    test "parallel integer encoding produces consistent results" do
      # Test values
      values = [-100, -1, 0, 1, 42, 100, 1000]

      # Encode each value 10 times in parallel
      tasks =
        for value <- values, _ <- 1..10 do
          Task.async(fn ->
            {:ok, id} = Dictionary.encode_integer(value)
            {:ok, decoded} = Dictionary.decode_integer(id)
            {value, decoded}
          end)
        end

      results = Task.await_many(tasks)

      # All roundtrips should be correct
      for {original, decoded} <- results do
        assert original == decoded
      end
    end

    test "parallel mixed type encoding" do
      # Mix different types of operations
      tasks =
        for i <- 1..100 do
          Task.async(fn ->
            case rem(i, 3) do
              0 ->
                {:ok, id} = Dictionary.encode_integer(i)
                {:integer, i, id}

              1 ->
                id = Dictionary.encode_id(Dictionary.type_uri(), i)
                {:uri, i, id}

              2 ->
                dt = DateTime.utc_now()
                {:ok, id} = Dictionary.encode_datetime(dt)
                {:datetime, DateTime.to_unix(dt, :millisecond), id}
            end
          end)
        end

      results = Task.await_many(tasks)

      # Verify each result
      for {type, _original, id} <- results do
        case type do
          :integer -> assert Dictionary.term_type(id) == :integer
          :uri -> assert Dictionary.term_type(id) == :uri
          :datetime -> assert Dictionary.term_type(id) == :datetime
        end
      end
    end
  end

  describe "concurrent validation" do
    test "parallel validation operations are consistent" do
      valid_term = "http://example.org/resource"
      invalid_term = String.duplicate("x", Dictionary.max_term_size() + 1)

      tasks =
        for _ <- 1..50 do
          [
            Task.async(fn -> Dictionary.validate_term(valid_term, :uri) end),
            Task.async(fn -> Dictionary.validate_term(invalid_term, :uri) end)
          ]
        end
        |> List.flatten()

      results = Task.await_many(tasks)

      valid_results = Enum.take_every(results, 2)
      invalid_results = results |> Enum.drop(1) |> Enum.take_every(2)

      assert Enum.all?(valid_results, &(&1 == :ok))
      assert Enum.all?(invalid_results, &(&1 == {:error, :term_too_large}))
    end
  end

  describe "concurrent type checking" do
    test "parallel inline_encoded? checks" do
      uri_id = Dictionary.encode_id(Dictionary.type_uri(), 1)
      {:ok, int_id} = Dictionary.encode_integer(42)

      tasks =
        for _ <- 1..100 do
          [
            Task.async(fn -> {Dictionary.inline_encoded?(uri_id), :uri} end),
            Task.async(fn -> {Dictionary.inline_encoded?(int_id), :int} end)
          ]
        end
        |> List.flatten()

      results = Task.await_many(tasks)

      for {is_inline, type} <- results do
        case type do
          :uri -> refute is_inline
          :int -> assert is_inline
        end
      end
    end
  end

  describe "stress testing" do
    @tag :slow
    test "high concurrency encoding stress test" do
      # This test verifies the pure functions are truly thread-safe
      num_processes = 50
      operations_per_process = 100

      tasks =
        for _ <- 1..num_processes do
          Task.async(fn ->
            for i <- 1..operations_per_process do
              # Mix of operations
              id = Dictionary.encode_id(Dictionary.type_uri(), i)
              {type, value} = Dictionary.decode_id(id)
              assert type == :uri
              assert value == i

              {:ok, int_id} = Dictionary.encode_integer(i)
              {:ok, decoded} = Dictionary.decode_integer(int_id)
              assert decoded == i
            end

            :ok
          end)
        end

      results = Task.await_many(tasks, 30_000)
      assert Enum.all?(results, &(&1 == :ok))
    end
  end
end
