# Agent Prompt: Implement Database Pool for Test Performance

## Objective

Implement a database pool solution to speed up the test suite by ~20x. Currently each test opens a new RocksDB database (~30ms overhead). The pool pre-creates databases and reuses them across tests.

## Required Reading (Read These Files First)

```
# Understand the NIF interface
lib/triple_store/backend/rocksdb/nif.ex

# Understand current test patterns - read ALL of these
test/test_helper.exs
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

# Reference documentation
docs/20251222/test-performance-optimization/solution-db-pool.md
```

## Files to Create

### 1. `test/support/test_helpers.ex`

```elixir
defmodule TripleStore.TestHelpers do
  @moduledoc "Shared test utilities with portable tmpdir detection."

  def test_tmpdir do
    case System.get_env("TRIPLE_STORE_TEST_TMPDIR") do
      nil -> if File.dir?("/dev/shm"), do: "/dev/shm", else: System.tmp_dir!()
      dir -> dir
    end
  end

  def test_db_path(name) do
    Path.join(test_tmpdir(), "triple_store_#{name}_#{:erlang.unique_integer([:positive])}")
  end

  def cleanup_test_db(path), do: File.rm_rf(path)
end
```

### 2. `test/support/db_pool.ex`

Create a GenServer that:
- Starts with `pool_size` databases (default: `System.schedulers_online()`)
- Each DB is opened via `NIF.open/1` at pool start
- `checkout/0` returns a `%{db: db_ref, path: path, id: id}` map
- `checkin/1` clears all data from the DB and returns it to available pool
- Clearing uses `NIF.prefix_iterator/3` + `NIF.delete/3` for each column family
- Column families to clear: `[:id2str, :str2id, :spo, :pos, :osp, :derived]`
- Handle waiters via `:queue` when pool is exhausted
- Clean up all DBs on terminate

### 3. `test/support/pooled_db_case.ex`

```elixir
defmodule TripleStore.PooledDbCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      use ExUnit.Case, async: true
      alias TripleStore.Backend.RocksDB.NIF
    end
  end

  setup do
    db_info = TripleStore.Test.DbPool.checkout()
    on_exit(fn -> TripleStore.Test.DbPool.checkin(db_info) end)
    {:ok, db: db_info.db, db_path: db_info.path}
  end
end
```

## Files to Modify

### `test/test_helper.exs`

```elixir
ExUnit.start()

# Load support modules
Code.require_file("support/test_helpers.ex", __DIR__)
Code.require_file("support/db_pool.ex", __DIR__)
Code.require_file("support/pooled_db_case.ex", __DIR__)

# Start the pool
{:ok, _} = TripleStore.Test.DbPool.start_link()
```

### All Test Files Using `NIF.open`

Transform from:
```elixir
defmodule SomeTest do
  use ExUnit.Case, async: true  # or async: false
  alias TripleStore.Backend.RocksDB.NIF

  @test_db_base "/tmp/..."

  setup do
    test_path = "#{@test_db_base}_#{:erlang.unique_integer([:positive])}"
    {:ok, db} = NIF.open(test_path)
    on_exit(fn ->
      NIF.close(db)
      File.rm_rf(test_path)
    end)
    {:ok, db: db}
  end
```

To:
```elixir
defmodule SomeTest do
  use TripleStore.PooledDbCase

  # Remove @test_db_base
  # Remove setup block
  # Tests receive %{db: db, db_path: path} automatically
```

## Special Cases

### `lifecycle_test.exs` - DO NOT MIGRATE

This file tests database open/close behavior and MUST keep its own setup:
```elixir
# Keep using direct NIF.open calls - these tests verify DB lifecycle
```

### Tests that create additional databases

Some tests open secondary databases (e.g., `"#{path}_closed"`). These must still use `NIF.open/NIF.close` directly for the secondary DB.

### Tests checking path via `%{path: path}`

Update pattern match from `%{path: path}` to `%{db_path: path}`.

## Column Family Atoms

The NIF uses atoms for column families. Use these exactly:
- `:id2str`
- `:str2id`
- `:spo`
- `:pos`
- `:osp`
- `:derived`

## Verification Steps

After implementation:

```bash
# Compile with no warnings
mix compile --warnings-as-errors

# Run dialyzer
mix dialyzer

# Run all tests
mix test

# Verify speedup (should be <1 second total vs ~4+ seconds before)
time mix test
```

## Expected Test Count

All 87+ tests should pass. No new tests need to be written.

## Implementation Order

1. Create `test/support/test_helpers.ex`
2. Create `test/support/db_pool.ex`
3. Create `test/support/pooled_db_case.ex`
4. Update `test/test_helper.exs`
5. Migrate test files one by one (skip `lifecycle_test.exs`)
6. Run `mix test` after each file to verify
7. Run `mix compile --warnings-as-errors` at end
8. Run `mix dialyzer` at end

## Critical Requirements

- No compiler warnings
- No dialyzer errors
- All tests pass
- Do not modify `lifecycle_test.exs` setup pattern
- Use `async: true` in PooledDbCase (pool handles concurrency)
- Pool GenServer must be named `TripleStore.Test.DbPool`
