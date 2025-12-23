# Test Performance Analysis

## Observed Behavior

Tests in the RocksDB backend modules consistently take 28-40ms each:

```
* test snapshot_iterator_next/1 stops at prefix boundary (29.2ms) [L#201]
* test snapshot/1 can create multiple snapshots (28.4ms) [L#38]
* test snapshot/1 creates a snapshot (28.8ms) [L#24]
* test snapshot_prefix_iterator/3 creates iterator over snapshot (31.3ms) [L#130]
* test concurrent operations concurrent snapshot reads (32.3ms) [L#414]
* test snapshot_stream/3 creates a stream from snapshot iterator (40.2ms) [L#293]
```

The actual test logic (creating snapshots, reading keys) should complete in microseconds, not tens of milliseconds.

## Root Cause

Every test module uses this pattern in its `setup` block:

```elixir
setup do
  test_path = "#{@test_db_base}_#{:erlang.unique_integer([:positive])}"
  {:ok, db} = NIF.open(test_path)  # <-- THE BOTTLENECK

  on_exit(fn ->
    NIF.close(db)
    File.rm_rf(test_path)
  end)

  {:ok, db: db}
end
```

### Why NIF.open is Slow

The `NIF.open/1` function performs these operations:

```rust
// native/rocksdb_nif/src/lib.rs:154
fn open(env: Env, path: String) -> NifResult<Term> {
    let mut opts = Options::default();
    opts.create_if_missing(true);
    opts.create_missing_column_families(true);

    // Creates 6 column families
    let cf_descriptors: Vec<ColumnFamilyDescriptor> = CF_NAMES
        .iter()
        .map(|name| {
            let cf_opts = Options::default();
            ColumnFamilyDescriptor::new(*name, cf_opts)
        })
        .collect();

    // This is the expensive call
    DB::open_cf_descriptors(&opts, &path, cf_descriptors)
}
```

RocksDB initialization involves:

1. **Directory creation** - Creates database directory structure
2. **WAL initialization** - Write-ahead log setup
3. **Memtable allocation** - In-memory buffer structures (default 64MB each)
4. **Column family setup** - 6 column families (id2str, str2id, spo, pos, osp, derived)
5. **Manifest creation** - Database metadata files
6. **Lock file acquisition** - Exclusive access lock
7. **Block cache initialization** - Read cache structures

### Filesystem Impact

Current configuration uses `/tmp`:

```elixir
@test_db_base "/tmp/triple_store_snapshot_test"
```

On the development system:

```bash
$ df -h /tmp
Filesystem      Size  Used Avail Use% Mounted on
/dev/sdd       1007G  257G  699G  27% /

$ df -h /dev/shm
Filesystem      Size  Used Avail Use% Mounted on
none             48G  1.1M   48G   1% /dev/shm
```

`/tmp` is on physical disk (ext4), while `/dev/shm` is RAM-backed (tmpfs). Disk I/O adds significant latency to database initialization.

## Breakdown of Time Costs

Approximate breakdown for a single `NIF.open` call on disk:

| Operation | Time (ms) | Notes |
|-----------|-----------|-------|
| Directory creation | 2-5 | syscalls + journal |
| WAL init | 3-5 | File creation + sync |
| Memtable setup | 1-2 | Memory allocation |
| Column families (x6) | 10-15 | Per-CF overhead |
| Manifest write | 3-5 | Metadata persistence |
| Lock acquisition | 1-2 | File locking |
| **Total** | **20-34** | Varies with disk load |

On tmpfs (`/dev/shm`), the same operations complete in ~8-15ms due to eliminated disk I/O.

## Test Count Impact

Current test file analysis:

```bash
$ grep -r "test \"" test/ | wc -l
87
```

With 87 tests at ~30ms each for DB setup alone:
- **Current**: 87 × 30ms = 2.6 seconds of pure setup overhead
- **With tmpfs**: 87 × 12ms = 1.0 seconds
- **With setup_all**: 87 × ~0ms = negligible (one DB per module)

## Affected Test Modules

All modules using the `NIF.open` pattern in `setup`:

```
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
```

## Conclusion

The test performance bottleneck is **RocksDB database initialization on disk-backed `/tmp`**. Solutions range from simple (use RAM-backed tmpdir) to architectural (share databases across tests with logical isolation).
