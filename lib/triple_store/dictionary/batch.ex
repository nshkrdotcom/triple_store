defmodule TripleStore.Dictionary.Batch do
  @moduledoc """
  Batch processing utilities for dictionary operations.

  Provides common patterns for processing lists of terms or IDs with
  proper error handling and early termination on failure.
  """

  @doc """
  Maps a function over a list, collecting results until an error is encountered.

  This pattern is used throughout the dictionary module for batch operations.
  Processing stops early if any item returns an error, preserving the error
  for the caller.

  ## Arguments

  - `items` - List of items to process
  - `fun` - Function that takes an item and returns `{:ok, result}`,
            `:not_found`, or `{:error, reason}`

  ## Returns

  - `{:ok, results}` - List of processed results in same order as input
  - `{:error, reason}` - First error encountered during processing

  ## Examples

      iex> Batch.map_with_early_error([1, 2, 3], fn x -> {:ok, x * 2} end)
      {:ok, [2, 4, 6]}

      iex> Batch.map_with_early_error([1, 2], fn _ -> {:error, :fail} end)
      {:error, :fail}
  """
  @spec map_with_early_error(list(), (term() -> {:ok, term()} | :not_found | {:error, term()})) ::
          {:ok, list()} | {:error, term()}
  def map_with_early_error(items, fun) do
    results =
      Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
        case fun.(item) do
          {:ok, result} -> {:cont, {:ok, [{:ok, result} | acc]}}
          :not_found -> {:cont, {:ok, [:not_found | acc]}}
          {:error, _} = error -> {:halt, error}
        end
      end)

    case results do
      {:ok, results_list} -> {:ok, Enum.reverse(results_list)}
      {:error, _} = error -> error
    end
  end

  @doc """
  Maps a function over a list, collecting only successful results.

  Unlike `map_with_early_error/2`, this variant collects only the unwrapped
  success values, suitable for operations like `get_or_create_ids` where
  every item should succeed.

  ## Arguments

  - `items` - List of items to process
  - `fun` - Function that takes an item and returns `{:ok, result}` or `{:error, reason}`

  ## Returns

  - `{:ok, results}` - List of unwrapped successful results
  - `{:error, reason}` - First error encountered

  ## Examples

      iex> Batch.map_collect_success([1, 2, 3], fn x -> {:ok, x * 2} end)
      {:ok, [2, 4, 6]}
  """
  @spec map_collect_success(list(), (term() -> {:ok, term()} | {:error, term()})) ::
          {:ok, list()} | {:error, term()}
  def map_collect_success(items, fun) do
    results =
      Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
        case fun.(item) do
          {:ok, result} -> {:cont, {:ok, [result | acc]}}
          {:error, _} = error -> {:halt, error}
        end
      end)

    case results do
      {:ok, results_list} -> {:ok, Enum.reverse(results_list)}
      {:error, _} = error -> error
    end
  end
end
