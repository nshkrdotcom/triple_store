# Solution: Portable Tmpdir with RAM-Disk Detection

## Overview

Replace hardcoded `/tmp` paths with a centralized helper that automatically detects and uses RAM-backed storage when available, while remaining fully portable across Linux, macOS, and Windows.

## Expected Improvement

- **Linux with /dev/shm**: ~2x speedup (30ms → 12-15ms per test)
- **macOS/Windows**: No change (uses system tmpdir)
- **Effort**: 30 minutes

## Implementation

### 1. Create Test Helper Module

Create `test/support/test_helpers.ex`:

```elixir
defmodule TripleStore.TestHelpers do
  @moduledoc """
  Shared utilities for TripleStore tests.

  Provides portable temporary directory handling with automatic
  RAM-disk detection for improved test performance on Linux.
  """

  @doc """
  Returns the base directory for test databases.

  Automatically detects and prefers RAM-backed storage:
  - Linux: Uses /dev/shm if available (tmpfs)
  - macOS/Windows: Uses system temp directory

  Can be overridden via TRIPLE_STORE_TEST_TMPDIR environment variable.

  ## Examples

      iex> TripleStore.TestHelpers.test_tmpdir()
      "/dev/shm"  # on Linux with /dev/shm

      iex> TripleStore.TestHelpers.test_tmpdir()
      "/tmp"  # on macOS
  """
  @spec test_tmpdir() :: String.t()
  def test_tmpdir do
    case System.get_env("TRIPLE_STORE_TEST_TMPDIR") do
      nil -> detect_tmpdir()
      dir -> dir
    end
  end

  @doc """
  Generates a unique test database path.

  ## Parameters

  - `name` - A descriptive name for the test database (e.g., "snapshot", "iterator")

  ## Examples

      iex> TripleStore.TestHelpers.test_db_path("snapshot")
      "/dev/shm/triple_store_snapshot_12345"
  """
  @spec test_db_path(String.t()) :: String.t()
  def test_db_path(name) when is_binary(name) do
    unique_id = :erlang.unique_integer([:positive])
    Path.join(test_tmpdir(), "triple_store_#{name}_#{unique_id}")
  end

  @doc """
  Generates a unique test database path with custom prefix.

  Useful when you need multiple related databases in a single test.

  ## Examples

      iex> TripleStore.TestHelpers.test_db_path("snapshot", "primary")
      "/dev/shm/triple_store_snapshot_primary_12345"
  """
  @spec test_db_path(String.t(), String.t()) :: String.t()
  def test_db_path(name, suffix) when is_binary(name) and is_binary(suffix) do
    unique_id = :erlang.unique_integer([:positive])
    Path.join(test_tmpdir(), "triple_store_#{name}_#{suffix}_#{unique_id}")
  end

  @doc """
  Cleans up a test database directory.

  Safe to call even if the path doesn't exist.
  """
  @spec cleanup_test_db(String.t()) :: :ok
  def cleanup_test_db(path) when is_binary(path) do
    File.rm_rf(path)
    :ok
  end

  @doc """
  Standard setup for tests requiring a RocksDB database.

  Returns a map suitable for ExUnit's setup callback.
  Automatically registers cleanup on test exit.

  ## Examples

      setup do
        TripleStore.TestHelpers.setup_test_db("my_test")
      end
  """
  @spec setup_test_db(String.t()) :: {:ok, map()}
  def setup_test_db(name) do
    alias TripleStore.Backend.RocksDB.NIF

    path = test_db_path(name)
    {:ok, db} = NIF.open(path)

    ExUnit.Callbacks.on_exit(fn ->
      NIF.close(db)
      cleanup_test_db(path)
    end)

    {:ok, %{db: db, db_path: path}}
  end

  # Private functions

  defp detect_tmpdir do
    cond do
      # Linux: prefer /dev/shm (tmpfs, RAM-backed)
      File.dir?("/dev/shm") and writable?("/dev/shm") ->
        "/dev/shm"

      # macOS: /tmp is often a symlink to a RAM-backed location
      # but we use System.tmp_dir! for portability
      true ->
        System.tmp_dir!()
    end
  end

  defp writable?(path) do
    test_file = Path.join(path, ".triple_store_write_test_#{:erlang.unique_integer([:positive])}")

    case File.write(test_file, "test") do
      :ok ->
        File.rm(test_file)
        true

      {:error, _} ->
        false
    end
  end
end
```

### 2. Update test_helper.exs

Ensure the helper is compiled and available:

```elixir
# test/test_helper.exs
ExUnit.start()

# Ensure test support modules are compiled
Code.require_file("support/test_helpers.ex", __DIR__)
```

### 3. Update Test Modules

Before:
```elixir
defmodule TripleStore.Backend.RocksDB.SnapshotTest do
  use ExUnit.Case, async: true
  alias TripleStore.Backend.RocksDB.NIF

  @test_db_base "/tmp/triple_store_snapshot_test"

  setup do
    test_path = "#{@test_db_base}_#{:erlang.unique_integer([:positive])}"
    {:ok, db} = NIF.open(test_path)

    on_exit(fn ->
      NIF.close(db)
      File.rm_rf(test_path)
    end)

    {:ok, db: db}
  end

  # tests...
end
```

After:
```elixir
defmodule TripleStore.Backend.RocksDB.SnapshotTest do
  use ExUnit.Case, async: true
  alias TripleStore.Backend.RocksDB.NIF
  import TripleStore.TestHelpers

  setup do
    setup_test_db("snapshot")
  end

  # tests...
end
```

Or, if you need more control:

```elixir
defmodule TripleStore.Backend.RocksDB.SnapshotTest do
  use ExUnit.Case, async: true
  alias TripleStore.Backend.RocksDB.NIF
  alias TripleStore.TestHelpers

  setup do
    test_path = TestHelpers.test_db_path("snapshot")
    {:ok, db} = NIF.open(test_path)

    on_exit(fn ->
      NIF.close(db)
      TestHelpers.cleanup_test_db(test_path)
    end)

    {:ok, db: db, db_path: test_path}
  end

  # tests...
end
```

## Environment Variable Override

For CI systems or custom setups, the temp directory can be overridden:

```bash
# Use a specific directory
TRIPLE_STORE_TEST_TMPDIR=/mnt/ramdisk mix test

# Force disk-based testing (for debugging)
TRIPLE_STORE_TEST_TMPDIR=/tmp mix test
```

## Platform Behavior

### Linux

1. Checks if `/dev/shm` exists and is writable
2. If yes, uses `/dev/shm` (RAM-backed tmpfs)
3. If no, falls back to `System.tmp_dir!()` (typically `/tmp`)

### macOS

1. `/dev/shm` does not exist
2. Uses `System.tmp_dir!()` (typically `/var/folders/.../T/`)
3. macOS temp directories are often RAM-backed or SSD-cached

### Windows

1. `/dev/shm` does not exist
2. Uses `System.tmp_dir!()` (typically `C:\Users\<user>\AppData\Local\Temp`)

## Verification

After implementation, verify the speedup:

```bash
# Check which tmpdir is being used
iex -S mix
iex> TripleStore.TestHelpers.test_tmpdir()
"/dev/shm"

# Run tests and compare timing
mix test test/triple_store/backend/rocksdb/snapshot_test.exs
```

Expected output on Linux:
```
* test snapshot/1 creates a snapshot (12.1ms)  # was 28.8ms
* test snapshot/1 can create multiple snapshots (11.8ms)  # was 28.4ms
```

## Rollout Strategy

1. Add `test/support/test_helpers.ex`
2. Update `test/test_helper.exs` to require it
3. Update test files one module at a time
4. Verify each module still passes
5. Remove old `@test_db_base` module attributes

## Files to Update

```
test/support/test_helpers.ex (new)
test/test_helper.exs (modify)
test/triple_store/backend/rocksdb/snapshot_test.exs
test/triple_store/backend/rocksdb/integration_test.exs
test/triple_store/backend/rocksdb/lifecycle_test.exs
test/triple_store/backend/rocksdb/read_write_test.exs
test/triple_store/backend/rocksdb/iterator_test.exs
test/triple_store/backend/rocksdb/write_batch_test.exs
test/triple_store/dictionary/sequence_counter_test.exs
test/triple_store/dictionary/id_to_string_test.exs
test/triple_store/dictionary/string_to_id_test.exs
test/triple_store/adapter/term_conversion_test.exs
test/triple_store/index/triple_insert_test.exs
test/triple_store/index/triple_delete_test.exs
test/triple_store/index/index_lookup_test.exs
test/support/index_test_helper.ex
```
