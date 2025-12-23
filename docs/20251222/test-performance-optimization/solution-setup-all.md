# Solution: Shared Database with setup_all

## Overview

Replace per-test database creation with a single shared database per test module. Tests are isolated using unique key prefixes rather than separate databases.

## Expected Improvement

- **Speedup**: ~10-20x (30ms → 1-3ms per test)
- **Effort**: 2-3 hours
- **Trade-off**: Tests share a database; requires key isolation discipline

## How It Works

### Before: One Database Per Test

```
Test 1: open DB → run test → close DB    [30ms + test time]
Test 2: open DB → run test → close DB    [30ms + test time]
Test 3: open DB → run test → close DB    [30ms + test time]
```

### After: Shared Database with Key Prefixes

```
Module setup: open DB                      [30ms, once]
  Test 1: use prefix "t1_" → run test     [<1ms + test time]
  Test 2: use prefix "t2_" → run test     [<1ms + test time]
  Test 3: use prefix "t3_" → run test     [<1ms + test time]
Module teardown: close DB
```

## Implementation

### 1. Create Shared Database Test Case

Create `test/support/shared_db_case.ex`:

```elixir
defmodule TripleStore.SharedDbCase do
  @moduledoc """
  ExUnit case template for tests that share a RocksDB database.

  Provides significant performance improvement by opening the database
  once per module instead of once per test. Tests are isolated using
  unique key prefixes.

  ## Usage

      defmodule MyTest do
        use TripleStore.SharedDbCase, db_name: "my_feature"

        test "something", %{db: db, prefix: prefix} do
          # Use prefix for all keys to avoid test interference
          key = prefix <> "my_key"
          NIF.put(db, "default", key, "value")
        end
      end

  ## How Isolation Works

  Each test receives a unique `prefix` in its context. All keys written
  by the test should use this prefix:

      # Good - isolated
      NIF.put(db, cf, prefix <> "user:1", value)

      # Bad - may conflict with other tests
      NIF.put(db, cf, "user:1", value)

  ## Options

  - `:db_name` - Required. Name for the shared database (used in path).
  - `:async` - Optional. Whether tests run async (default: true).
  """

  use ExUnit.CaseTemplate
  alias TripleStore.Backend.RocksDB.NIF
  alias TripleStore.TestHelpers

  using opts do
    db_name = Keyword.fetch!(opts, :db_name)
    async = Keyword.get(opts, :async, true)

    quote do
      use ExUnit.Case, async: unquote(async)
      alias TripleStore.Backend.RocksDB.NIF

      @db_name unquote(db_name)

      setup_all do
        path = TestHelpers.test_db_path(@db_name)
        {:ok, db} = NIF.open(path)

        on_exit(fn ->
          NIF.close(db)
          TestHelpers.cleanup_test_db(path)
        end)

        %{db: db, db_path: path}
      end

      setup context do
        # Generate unique prefix for this test
        prefix = "t#{:erlang.unique_integer([:positive])}_"
        Map.put(context, :prefix, prefix)
      end
    end
  end
end
```

### 2. Create Prefixed Key Helpers

Add to `test/support/test_helpers.ex`:

```elixir
defmodule TripleStore.TestHelpers do
  # ... existing code ...

  @doc """
  Creates a prefixed key for test isolation.

  ## Examples

      iex> prefixed_key("t123_", "user:1")
      "t123_user:1"
  """
  @spec prefixed_key(String.t(), String.t()) :: String.t()
  def prefixed_key(prefix, key) when is_binary(prefix) and is_binary(key) do
    prefix <> key
  end

  @doc """
  Creates a prefixed key from binary components.
  Useful for triple indices where keys are raw binaries.

  ## Examples

      iex> prefixed_binary("t123_", <<1, 2, 3>>)
      <<"t123_", 1, 2, 3>>
  """
  @spec prefixed_binary(String.t(), binary()) :: binary()
  def prefixed_binary(prefix, binary) when is_binary(prefix) and is_binary(binary) do
    prefix <> binary
  end

  @doc """
  Deletes all keys with a given prefix from a column family.
  Useful for cleanup between tests if needed.
  """
  @spec delete_prefixed_keys(reference(), String.t(), String.t()) :: :ok
  def delete_prefixed_keys(db, cf, prefix) do
    alias TripleStore.Backend.RocksDB.NIF

    {:ok, iterator} = NIF.prefix_iterator(db, cf, prefix)
    delete_iterator_keys(db, cf, iterator)
  end

  defp delete_iterator_keys(db, cf, iterator) do
    alias TripleStore.Backend.RocksDB.NIF

    case NIF.iterator_next(iterator) do
      {:ok, key, _value} ->
        NIF.delete(db, cf, key)
        delete_iterator_keys(db, cf, iterator)

      :done ->
        NIF.iterator_close(iterator)
        :ok
    end
  end
end
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

  test "creates a snapshot", %{db: db} do
    NIF.put(db, "default", "key1", "value1")
    {:ok, snapshot} = NIF.snapshot(db)
    assert is_reference(snapshot)
  end
end
```

After:
```elixir
defmodule TripleStore.Backend.RocksDB.SnapshotTest do
  use TripleStore.SharedDbCase, db_name: "snapshot"

  test "creates a snapshot", %{db: db, prefix: prefix} do
    key = prefix <> "key1"
    NIF.put(db, "default", key, "value1")
    {:ok, snapshot} = NIF.snapshot(db)
    assert is_reference(snapshot)
  end
end
```

### 4. Handling Tests That Need Fresh Database

Some tests may require a completely fresh database (e.g., testing empty-database behavior). Create a hybrid approach:

```elixir
defmodule TripleStore.Backend.RocksDB.LifecycleTest do
  use ExUnit.Case, async: true
  alias TripleStore.Backend.RocksDB.NIF
  import TripleStore.TestHelpers

  # These tests need fresh databases - can't share
  describe "database lifecycle" do
    test "open creates new database" do
      path = test_db_path("lifecycle_open")
      refute File.exists?(path)

      {:ok, db} = NIF.open(path)
      assert File.exists?(path)

      NIF.close(db)
      cleanup_test_db(path)
    end

    test "close releases resources" do
      path = test_db_path("lifecycle_close")
      {:ok, db} = NIF.open(path)
      assert :ok = NIF.close(db)

      # Verify can reopen
      {:ok, db2} = NIF.open(path)
      NIF.close(db2)
      cleanup_test_db(path)
    end
  end
end
```

## Key Prefix Patterns

### Simple String Keys

```elixir
test "stores user data", %{db: db, prefix: prefix} do
  key = prefix <> "user:123"
  NIF.put(db, "default", key, "data")
end
```

### Binary Triple Keys

For triple indices with binary-encoded keys:

```elixir
test "stores triple in SPO index", %{db: db, prefix: prefix} do
  # Encode triple as usual
  triple_key = <<subject_id::64, predicate_id::64, object_id::64>>

  # Prefix for isolation
  prefixed = prefix <> triple_key

  NIF.put(db, "spo", prefixed, <<>>)
end
```

### Dictionary Keys

```elixir
test "stores string to ID mapping", %{db: db, prefix: prefix} do
  term = "http://example.org/subject"
  key = prefix <> term

  NIF.put(db, "str2id", key, <<123::64>>)
end
```

## Handling Column Families

The shared database has all column families available. Tests can use any CF with their prefix:

```elixir
test "writes to multiple column families", %{db: db, prefix: prefix} do
  # All use same prefix for isolation
  NIF.put(db, "str2id", prefix <> "term1", <<1::64>>)
  NIF.put(db, "id2str", prefix <> <<1::64>>, "term1")
  NIF.put(db, "spo", prefix <> <<1::64, 2::64, 3::64>>, <<>>)
end
```

## Considerations

### When to Use Shared Database

Good candidates:
- Read/write operation tests
- Iterator tests
- Snapshot tests
- Dictionary encoding tests
- Index operation tests

### When to Use Fresh Database

Keep per-test databases for:
- Database lifecycle tests (open/close)
- Tests that verify empty-database behavior
- Tests that check database file structure
- Corruption/recovery tests

### Async Safety

With key prefixes, tests are safely isolated even with `async: true`:

```elixir
use TripleStore.SharedDbCase, db_name: "my_feature", async: true
```

Each test gets a unique prefix like `t847293_`, ensuring no key collisions.

### Memory Considerations

A single database uses more memory than opening/closing:
- Memtables stay allocated for the module duration
- Block cache accumulates entries

For test suites, this is typically acceptable. If memory becomes an issue, split into smaller test modules.

## Migration Checklist

For each test file:

1. [ ] Replace `use ExUnit.Case` with `use TripleStore.SharedDbCase, db_name: "..."`
2. [ ] Remove `setup` block that opens database
3. [ ] Add `prefix` to test function pattern match: `test "...", %{db: db, prefix: prefix}`
4. [ ] Prefix all keys with `prefix <> ...`
5. [ ] Remove `@test_db_base` module attribute
6. [ ] Run tests to verify isolation works

## Expected Results

Before:
```
Finished in 4.2 seconds
87 tests, 0 failures
```

After:
```
Finished in 0.8 seconds
87 tests, 0 failures
```
