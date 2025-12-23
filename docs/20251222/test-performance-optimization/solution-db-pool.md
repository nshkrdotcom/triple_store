# Solution: Database Pool Architecture

## Overview

Maintain a pool of pre-initialized RocksDB databases that tests can check out, use, and return. Databases are reset between uses rather than recreated, eliminating initialization overhead entirely.

## Expected Improvement

- **Speedup**: ~20x+ (30ms → <1ms per test after warmup)
- **Effort**: 4-6 hours
- **Trade-off**: More complex infrastructure; pool management overhead

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Test Process                             │
│  test "my test" do                                          │
│    db = DbPool.checkout()                                   │
│    # use db...                                              │
│    DbPool.checkin(db)                                       │
│  end                                                        │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                   DbPool GenServer                           │
│  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐           │
│  │  DB 1   │ │  DB 2   │ │  DB 3   │ │  DB 4   │  ...      │
│  │ (avail) │ │ (in use)│ │ (avail) │ │ (avail) │           │
│  └─────────┘ └─────────┘ └─────────┘ └─────────┘           │
└─────────────────────────────────────────────────────────────┘
```

## Implementation

### 1. Database Pool GenServer

Create `test/support/db_pool.ex`:

```elixir
defmodule TripleStore.Test.DbPool do
  @moduledoc """
  A pool of pre-initialized RocksDB databases for testing.

  Databases are created once at pool startup and reused across tests.
  When a database is returned to the pool, it is cleared of all data
  but retains its initialized state (column families, caches, etc.).

  ## Configuration

  The pool size defaults to `System.schedulers_online()` but can be
  configured via the `TRIPLE_STORE_TEST_POOL_SIZE` environment variable.

  ## Usage

      # In test setup
      setup do
        db_ref = TripleStore.Test.DbPool.checkout()

        on_exit(fn ->
          TripleStore.Test.DbPool.checkin(db_ref)
        end)

        {:ok, db: db_ref.db, db_path: db_ref.path}
      end
  """

  use GenServer
  alias TripleStore.Backend.RocksDB.NIF
  alias TripleStore.TestHelpers

  @default_pool_size System.schedulers_online()
  @checkout_timeout 30_000

  # Client API

  @doc """
  Starts the database pool.

  Called automatically by test_helper.exs.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Checks out a database from the pool.

  Blocks until a database is available. Returns a reference struct
  containing the database handle and path.

  ## Options

  - `:timeout` - How long to wait for a database (default: 30 seconds)
  """
  def checkout(opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @checkout_timeout)
    GenServer.call(__MODULE__, :checkout, timeout)
  end

  @doc """
  Returns a database to the pool.

  The database will be cleared of all data before being made
  available for other tests.
  """
  def checkin(db_ref) do
    GenServer.cast(__MODULE__, {:checkin, db_ref})
  end

  @doc """
  Returns pool statistics for debugging.
  """
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @doc """
  Stops the pool and closes all databases.
  """
  def stop do
    GenServer.stop(__MODULE__)
  end

  # Server Implementation

  defmodule DbRef do
    @moduledoc false
    defstruct [:db, :path, :id]
  end

  @impl true
  def init(opts) do
    pool_size = opts[:pool_size] || get_pool_size()
    base_path = TestHelpers.test_tmpdir()

    # Create pool of databases
    databases =
      for i <- 1..pool_size do
        path = Path.join(base_path, "triple_store_pool_#{i}_#{:erlang.unique_integer([:positive])}")
        {:ok, db} = NIF.open(path)
        %DbRef{db: db, path: path, id: i}
      end

    state = %{
      available: databases,
      in_use: %{},
      waiters: :queue.new(),
      total: pool_size
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:checkout, from, state) do
    case state.available do
      [db_ref | rest] ->
        # Database available, check it out
        new_state = %{
          state
          | available: rest,
            in_use: Map.put(state.in_use, db_ref.id, {db_ref, from})
        }

        {:reply, db_ref, new_state}

      [] ->
        # No databases available, add to waiters queue
        new_waiters = :queue.in(from, state.waiters)
        {:noreply, %{state | waiters: new_waiters}}
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = %{
      total: state.total,
      available: length(state.available),
      in_use: map_size(state.in_use),
      waiting: :queue.len(state.waiters)
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_cast({:checkin, db_ref}, state) do
    # Clear all data from the database
    clear_database(db_ref.db)

    # Remove from in_use
    new_in_use = Map.delete(state.in_use, db_ref.id)

    # Check if anyone is waiting
    case :queue.out(state.waiters) do
      {{:value, waiter}, new_waiters} ->
        # Give database to waiter
        GenServer.reply(waiter, db_ref)

        new_state = %{
          state
          | in_use: Map.put(new_in_use, db_ref.id, {db_ref, waiter}),
            waiters: new_waiters
        }

        {:noreply, new_state}

      {:empty, _} ->
        # No waiters, add to available
        {:noreply, %{state | available: [db_ref | state.available], in_use: new_in_use}}
    end
  end

  @impl true
  def terminate(_reason, state) do
    # Close all databases
    Enum.each(state.available, fn db_ref ->
      NIF.close(db_ref.db)
      File.rm_rf(db_ref.path)
    end)

    Enum.each(state.in_use, fn {_id, {db_ref, _from}} ->
      NIF.close(db_ref.db)
      File.rm_rf(db_ref.path)
    end)

    :ok
  end

  # Private functions

  defp get_pool_size do
    case System.get_env("TRIPLE_STORE_TEST_POOL_SIZE") do
      nil -> @default_pool_size
      size -> String.to_integer(size)
    end
  end

  defp clear_database(db) do
    # Clear all column families
    for cf <- ["id2str", "str2id", "spo", "pos", "osp", "derived"] do
      clear_column_family(db, cf)
    end
  end

  defp clear_column_family(db, cf) do
    # Use iterator to find all keys, then delete
    case NIF.prefix_iterator(db, cf, <<>>) do
      {:ok, iterator} ->
        delete_all_keys(db, cf, iterator)

      {:error, _} ->
        :ok
    end
  end

  defp delete_all_keys(db, cf, iterator) do
    case NIF.iterator_next(iterator) do
      {:ok, key, _value} ->
        NIF.delete(db, cf, key)
        delete_all_keys(db, cf, iterator)

      :done ->
        NIF.iterator_close(iterator)
        :ok

      {:error, _} ->
        :ok
    end
  end
end
```

### 2. Optimized Clear with DeleteRange

For better performance, use RocksDB's DeleteRange if available:

```rust
// Add to native/rocksdb_nif/src/lib.rs

/// Deletes all keys in a column family using DeleteRange.
/// This is much faster than iterating and deleting individual keys.
#[rustler::nif(schedule = "DirtyCpu")]
fn delete_range(
    db_arc: ResourceArc<DbRef>,
    cf_name: String,
    start_key: Binary,
    end_key: Binary,
) -> NifResult<Term> {
    let db_guard = db_arc.db.read().map_err(|_| ...)?;
    let db = db_guard.as_ref().ok_or(...)?;

    let cf = db.cf_handle(&cf_name).ok_or(...)?;

    match db.delete_range_cf(cf, start_key.as_slice(), end_key.as_slice()) {
        Ok(()) => Ok(atoms::ok().encode(env)),
        Err(e) => Ok((atoms::error(), e.to_string()).encode(env)),
    }
}

/// Clears all data from a column family.
#[rustler::nif(schedule = "DirtyCpu")]
fn clear_column_family(
    db_arc: ResourceArc<DbRef>,
    cf_name: String,
) -> NifResult<Term> {
    let db_guard = db_arc.db.read().map_err(|_| ...)?;
    let db = db_guard.as_ref().ok_or(...)?;

    let cf = db.cf_handle(&cf_name).ok_or(...)?;

    // Delete from minimum to maximum key
    let start = vec![0u8; 0];
    let end = vec![0xFFu8; 256];  // Max possible key prefix

    match db.delete_range_cf(cf, &start, &end) {
        Ok(()) => Ok(atoms::ok().encode(env)),
        Err(e) => Ok((atoms::error(), e.to_string()).encode(env)),
    }
}
```

Then update the pool to use it:

```elixir
defp clear_column_family(db, cf) do
  case NIF.clear_column_family(db, cf) do
    :ok -> :ok
    {:error, _} -> clear_column_family_slow(db, cf)
  end
end
```

### 3. Pool-Aware Test Case

Create `test/support/pooled_db_case.ex`:

```elixir
defmodule TripleStore.PooledDbCase do
  @moduledoc """
  ExUnit case template using the database pool.

  ## Usage

      defmodule MyTest do
        use TripleStore.PooledDbCase

        test "something", %{db: db} do
          # Use the database
        end
      end
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      use ExUnit.Case, async: true
      alias TripleStore.Backend.RocksDB.NIF
    end
  end

  setup do
    db_ref = TripleStore.Test.DbPool.checkout()

    on_exit(fn ->
      TripleStore.Test.DbPool.checkin(db_ref)
    end)

    {:ok, db: db_ref.db, db_path: db_ref.path}
  end
end
```

### 4. Update test_helper.exs

```elixir
# test/test_helper.exs
ExUnit.start()

# Start the database pool before tests run
{:ok, _} = TripleStore.Test.DbPool.start_link()

# Ensure pool is stopped after tests complete
ExUnit.after_suite(fn _ ->
  TripleStore.Test.DbPool.stop()
end)
```

### 5. Update Test Modules

```elixir
defmodule TripleStore.Backend.RocksDB.SnapshotTest do
  use TripleStore.PooledDbCase

  test "creates a snapshot", %{db: db} do
    NIF.put(db, "default", "key1", "value1")
    {:ok, snapshot} = NIF.snapshot(db)
    assert is_reference(snapshot)
  end
end
```

## Pool Sizing

### Default Behavior

Pool size defaults to `System.schedulers_online()`:
- 8-core machine → 8 databases
- Tests run with `async: true` → max 8 concurrent tests using DBs

### Override via Environment

```bash
# Large test suite on beefy CI
TRIPLE_STORE_TEST_POOL_SIZE=16 mix test

# Memory-constrained environment
TRIPLE_STORE_TEST_POOL_SIZE=2 mix test
```

### Memory Calculation

Each RocksDB database uses approximately:
- ~64MB per memtable × 6 column families = ~384MB (with defaults)
- With smaller test config: ~64MB total

For a pool of 8 databases: 512MB - 3GB depending on configuration.

## RocksDB Test Options

Consider adding test-optimized RocksDB options:

```rust
fn open_for_testing(path: String) -> Result<DB, Error> {
    let mut opts = Options::default();
    opts.create_if_missing(true);
    opts.create_missing_column_families(true);

    // Test optimizations
    opts.set_write_buffer_size(1024 * 1024);  // 1MB instead of 64MB
    opts.set_max_write_buffer_number(2);
    opts.set_target_file_size_base(1024 * 1024);  // 1MB
    opts.set_max_background_jobs(1);
    opts.set_disable_auto_compactions(true);  // Faster for short-lived DBs

    // ... rest of setup
}
```

## Comparison with Other Approaches

| Aspect | Per-Test DB | setup_all | Pool |
|--------|-------------|-----------|------|
| Setup time | 30ms/test | 30ms/module | 30ms×N at start |
| Per-test overhead | 30ms | <1ms | <1ms |
| Memory | Low | Medium | High (N databases) |
| Isolation | Full | Logical | Full |
| Complexity | Simple | Medium | High |
| Async support | Yes | Yes | Yes |

## When to Use Pool

Best for:
- Large test suites (100+ tests)
- CI environments where startup cost is amortized
- Tests that need full isolation (not key-prefix based)
- Teams comfortable with pool infrastructure

Not ideal for:
- Small test suites
- Memory-constrained environments
- Tests that intentionally corrupt/break databases

## Debugging

### Check Pool Status

```elixir
# In IEx during test run
TripleStore.Test.DbPool.stats()
# => %{total: 8, available: 3, in_use: 5, waiting: 0}
```

### Pool Exhaustion

If tests timeout waiting for databases:

1. Increase pool size: `TRIPLE_STORE_TEST_POOL_SIZE=16`
2. Check for leaked databases (tests not calling checkin)
3. Reduce test parallelism: `mix test --max-cases 4`

### Monitoring

Add telemetry for observability:

```elixir
def checkout(opts \\ []) do
  start_time = System.monotonic_time()
  result = GenServer.call(__MODULE__, :checkout, timeout)
  duration = System.monotonic_time() - start_time

  :telemetry.execute(
    [:triple_store, :test, :db_pool, :checkout],
    %{duration: duration},
    %{pool_size: stats().total}
  )

  result
end
```

## Migration Path

1. Implement portable tmpdir (immediate win)
2. Add pool infrastructure
3. Create `PooledDbCase` template
4. Migrate test modules incrementally
5. Measure and tune pool size

## Files to Create/Modify

```
test/support/db_pool.ex (new)
test/support/pooled_db_case.ex (new)
test/test_helper.exs (modify)
native/rocksdb_nif/src/lib.rs (optional: add clear_column_family)
lib/triple_store/backend/rocksdb/nif.ex (optional: expose clear_column_family)
```
