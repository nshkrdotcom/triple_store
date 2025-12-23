# Migration Guide: Test Performance Optimization

This guide provides step-by-step instructions for implementing test performance improvements.

## Phase 1: Portable Tmpdir (30 minutes)

This phase provides immediate benefits with minimal code changes.

### Step 1.1: Create Test Helper Module

```bash
touch test/support/test_helpers.ex
```

Add the following content:

```elixir
defmodule TripleStore.TestHelpers do
  @moduledoc """
  Shared utilities for TripleStore tests.
  """

  @spec test_tmpdir() :: String.t()
  def test_tmpdir do
    case System.get_env("TRIPLE_STORE_TEST_TMPDIR") do
      nil -> detect_tmpdir()
      dir -> dir
    end
  end

  @spec test_db_path(String.t()) :: String.t()
  def test_db_path(name) when is_binary(name) do
    unique_id = :erlang.unique_integer([:positive])
    Path.join(test_tmpdir(), "triple_store_#{name}_#{unique_id}")
  end

  @spec cleanup_test_db(String.t()) :: :ok
  def cleanup_test_db(path) when is_binary(path) do
    File.rm_rf(path)
    :ok
  end

  defp detect_tmpdir do
    cond do
      File.dir?("/dev/shm") and writable?("/dev/shm") -> "/dev/shm"
      true -> System.tmp_dir!()
    end
  end

  defp writable?(path) do
    test_file = Path.join(path, ".triple_store_test_#{:erlang.unique_integer([:positive])}")
    case File.write(test_file, "test") do
      :ok -> File.rm(test_file); true
      {:error, _} -> false
    end
  end
end
```

### Step 1.2: Update test_helper.exs

Edit `test/test_helper.exs`:

```elixir
ExUnit.start()

# Compile test support modules
Code.require_file("support/test_helpers.ex", __DIR__)
```

### Step 1.3: Update Test Files

For each test file, replace the setup pattern:

**Before:**
```elixir
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
```

**After:**
```elixir
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
```

### Step 1.4: Files to Update

Run this command to find all files needing updates:

```bash
grep -l "@test_db_base" test/**/*.exs test/support/*.ex
```

Expected files:
- `test/triple_store/backend/rocksdb/snapshot_test.exs`
- `test/triple_store/backend/rocksdb/integration_test.exs`
- `test/triple_store/backend/rocksdb/lifecycle_test.exs`
- `test/triple_store/backend/rocksdb/read_write_test.exs`
- `test/triple_store/backend/rocksdb/iterator_test.exs`
- `test/triple_store/backend/rocksdb/write_batch_test.exs`
- `test/triple_store/dictionary/sequence_counter_test.exs`
- `test/triple_store/dictionary/id_to_string_test.exs`
- `test/triple_store/dictionary/string_to_id_test.exs`
- `test/triple_store/adapter/term_conversion_test.exs`
- `test/triple_store/index/triple_insert_test.exs`
- `test/triple_store/index/triple_delete_test.exs`
- `test/triple_store/index/index_lookup_test.exs`
- `test/support/index_test_helper.ex`

### Step 1.5: Verify

```bash
# Check tmpdir detection
mix run -e "IO.puts TripleStore.TestHelpers.test_tmpdir()"

# Run tests and compare timing
mix test 2>&1 | tail -5
```

### Expected Results

| Platform | Before | After |
|----------|--------|-------|
| Linux (with /dev/shm) | ~30ms/test | ~12-15ms/test |
| macOS | ~30ms/test | ~30ms/test (no change) |
| Windows | ~30ms/test | ~30ms/test (no change) |

---

## Phase 2: Shared Database with setup_all (2-3 hours)

This phase provides significant speedup by sharing databases within test modules.

### Step 2.1: Create SharedDbCase Module

```bash
touch test/support/shared_db_case.ex
```

Add content from [solution-setup-all.md](solution-setup-all.md#1-create-shared-database-test-case).

### Step 2.2: Update test_helper.exs

```elixir
ExUnit.start()

Code.require_file("support/test_helpers.ex", __DIR__)
Code.require_file("support/shared_db_case.ex", __DIR__)
```

### Step 2.3: Identify Candidate Modules

Good candidates for shared database:
- Tests that don't check empty-database behavior
- Tests that don't corrupt the database intentionally
- Tests with many individual test cases

```bash
# Count tests per module to prioritize
for f in test/**/*_test.exs; do
  count=$(grep -c "test \"" "$f" 2>/dev/null || echo 0)
  echo "$count $f"
done | sort -rn | head -10
```

### Step 2.4: Migrate a Test Module

Example migration for `snapshot_test.exs`:

**Before:**
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

    {:ok, db: db}
  end

  test "creates a snapshot", %{db: db} do
    NIF.put(db, "default", "key1", "value1")
    {:ok, snapshot} = NIF.snapshot(db)
    assert is_reference(snapshot)
  end

  test "reads from snapshot", %{db: db} do
    NIF.put(db, "default", "key1", "value1")
    {:ok, snapshot} = NIF.snapshot(db)
    {:ok, value} = NIF.snapshot_get(snapshot, "default", "key1")
    assert value == "value1"
  end
end
```

**After:**
```elixir
defmodule TripleStore.Backend.RocksDB.SnapshotTest do
  use TripleStore.SharedDbCase, db_name: "snapshot"

  test "creates a snapshot", %{db: db, prefix: prefix} do
    key = prefix <> "key1"
    NIF.put(db, "default", key, "value1")
    {:ok, snapshot} = NIF.snapshot(db)
    assert is_reference(snapshot)
  end

  test "reads from snapshot", %{db: db, prefix: prefix} do
    key = prefix <> "key1"
    NIF.put(db, "default", key, "value1")
    {:ok, snapshot} = NIF.snapshot(db)
    {:ok, value} = NIF.snapshot_get(snapshot, "default", key)
    assert value == "value1"
  end
end
```

### Step 2.5: Migration Checklist Per File

- [ ] Change `use ExUnit.Case` to `use TripleStore.SharedDbCase, db_name: "..."`
- [ ] Remove manual `setup` block with `NIF.open`
- [ ] Add `prefix` to all test function signatures
- [ ] Prefix all keys: `key = prefix <> "original_key"`
- [ ] Update any key comparisons to account for prefix
- [ ] Remove `@test_db_base` if present
- [ ] Run tests for this file: `mix test path/to/file.exs`

### Step 2.6: Handle Edge Cases

#### Tests Checking Specific Key Names

If a test asserts on key names from iteration:

```elixir
# Before
test "iterates keys", %{db: db} do
  NIF.put(db, "cf", "key1", "v1")
  NIF.put(db, "cf", "key2", "v2")
  keys = get_all_keys(db, "cf")
  assert keys == ["key1", "key2"]
end

# After
test "iterates keys", %{db: db, prefix: prefix} do
  NIF.put(db, "cf", prefix <> "key1", "v1")
  NIF.put(db, "cf", prefix <> "key2", "v2")
  keys = get_all_keys_with_prefix(db, "cf", prefix)
  assert keys == [prefix <> "key1", prefix <> "key2"]
end
```

#### Tests Needing Fresh Database

Keep these with per-test databases:

```elixir
defmodule TripleStore.Backend.RocksDB.LifecycleTest do
  # Don't use SharedDbCase - these need fresh DBs
  use ExUnit.Case, async: true
  alias TripleStore.TestHelpers

  test "open creates new database" do
    path = TestHelpers.test_db_path("lifecycle")
    # ... rest of test
  end
end
```

### Expected Results

| Metric | Before | After |
|--------|--------|-------|
| Time per test | 30ms | <3ms |
| Total suite time | 4.2s | 0.8s |
| Memory usage | Lower | Higher (fewer DB opens/closes) |

---

## Phase 3: Database Pool (4-6 hours)

This phase is optional and provides maximum performance for large test suites.

### Prerequisites

- Phase 1 (Portable Tmpdir) completed
- Familiarity with GenServer patterns
- Need for >10x speedup

### Step 3.1: Implement Pool

See [solution-db-pool.md](solution-db-pool.md) for complete implementation.

Create files:
- `test/support/db_pool.ex`
- `test/support/pooled_db_case.ex`

### Step 3.2: Optional NIF Enhancement

Add `clear_column_family` NIF for faster database reset:

```rust
// native/rocksdb_nif/src/lib.rs
#[rustler::nif(schedule = "DirtyCpu")]
fn clear_column_family(db_arc: ResourceArc<DbRef>, cf_name: String) -> NifResult<Term> {
    // Implementation in solution-db-pool.md
}
```

### Step 3.3: Update test_helper.exs

```elixir
ExUnit.start()

Code.require_file("support/test_helpers.ex", __DIR__)
Code.require_file("support/db_pool.ex", __DIR__)
Code.require_file("support/pooled_db_case.ex", __DIR__)

{:ok, _} = TripleStore.Test.DbPool.start_link()

ExUnit.after_suite(fn _ ->
  TripleStore.Test.DbPool.stop()
end)
```

### Step 3.4: Migrate Tests

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

---

## Verification Commands

### Check Current Performance

```bash
# Time full test suite
time mix test

# Time specific slow modules
time mix test test/triple_store/backend/rocksdb/
```

### Check Tmpdir Detection

```bash
mix run -e "IO.puts TripleStore.TestHelpers.test_tmpdir()"
```

### Check Pool Status (Phase 3)

```elixir
# During test run in IEx
TripleStore.Test.DbPool.stats()
```

---

## Rollback Plan

If issues arise, rollback is straightforward:

### Phase 1 Rollback

Revert `test_helpers.ex` usage back to hardcoded paths:

```elixir
@test_db_base "/tmp/triple_store_snapshot_test"
```

### Phase 2 Rollback

Replace `use TripleStore.SharedDbCase` with original pattern:

```elixir
use ExUnit.Case, async: true
# ... original setup block
```

### Phase 3 Rollback

Remove pool from `test_helper.exs` and revert to SharedDbCase or per-test DBs.

---

## Summary Checklist

### Phase 1: Portable Tmpdir
- [ ] Create `test/support/test_helpers.ex`
- [ ] Update `test/test_helper.exs` to require it
- [ ] Update all test files to use `TestHelpers.test_db_path/1`
- [ ] Remove `@test_db_base` module attributes
- [ ] Verify tests pass
- [ ] Measure improvement on Linux

### Phase 2: Shared Database
- [ ] Create `test/support/shared_db_case.ex`
- [ ] Update `test/test_helper.exs`
- [ ] Identify candidate test modules
- [ ] Migrate modules one at a time
- [ ] Add prefix to all keys in migrated tests
- [ ] Keep lifecycle tests with per-test DBs
- [ ] Verify tests pass after each migration
- [ ] Measure improvement

### Phase 3: Database Pool (Optional)
- [ ] Create `test/support/db_pool.ex`
- [ ] Create `test/support/pooled_db_case.ex`
- [ ] Optionally add `clear_column_family` NIF
- [ ] Update `test/test_helper.exs` to start pool
- [ ] Migrate test modules
- [ ] Tune pool size for environment
- [ ] Measure improvement
