# RocksDB NIF Lifetime Risk: Closing With Active Iterators/Snapshots

## Summary

There is a real safety risk if the RocksDB NIF `close/1` is called while any
iterator or snapshot created from that DB is still alive. The iterator/snapshot
objects are created with an unsafe lifetime extension and will keep a raw
pointer to the DB internals. If the DB is dropped, those iterators can become
use-after-free, which can crash the VM or return corrupted data.

This is not the `cf_name` warning. That warning is just a dead-code lint for an
unused field and does not affect runtime behavior.

## Where This Happens

### DB Close Drops the Handle

`native/rocksdb_nif/src/lib.rs`:

- `close/1` acquires a write lock and sets `DbRef.db` to `None`.
- This drops the `rocksdb::DB` value immediately.

### Iterators/Snapshots Use Unsafe Lifetime Extension

`native/rocksdb_nif/src/lib.rs`:

- `prefix_iterator/3` and `snapshot_prefix_iterator/3` create iterators and
  convert them to `'static` using `std::mem::transmute`.
- This is only safe if the DB stays alive for the lifetime of the iterator.
- The iterator is stored in `IteratorRef` / `SnapshotIteratorRef`, which keeps
  an `Arc<ResourceArc<DbRef>>` to "keep the DB alive".

However, the DB is not actually kept alive by the Arc alone; the DB lives in
`DbRef.db: RwLock<Option<DB>>`, and `close/1` sets it to `None`. The iterator
still points to the old DB internals after the DB is dropped.

## Why This Is Dangerous

Once `close/1` runs:

- the DB object is dropped,
- iterators/snapshots still hold a pointer into the freed DB,
- calling `iterator_next/1`, `iterator_collect/1`, `snapshot_get/3`, etc. can
  trigger UB in Rust (use-after-free), which can crash BEAM or corrupt data.

This is a classic lifetime/liveness mismatch: we made the iterator `'static`
and only *assumed* the DB outlived it.

## How to Test (Repro)

### Iterator After Close

Run in `iex -S mix` (from `/home/home/p/g/n/triple_store`):

```elixir
alias TripleStore.Backend.RocksDB.NIF

db_path = System.tmp_dir!() <> "/ts_risk_" <> Integer.to_string(System.unique_integer([:positive]))
{:ok, db} = NIF.open(db_path)

NIF.put(db, :spo, "s1p1o1", "")
{:ok, iter} = NIF.prefix_iterator(db, :spo, "s1")

# Drop the DB while iter is alive
NIF.close(db)

# This is the risky call (may crash or misbehave)
NIF.iterator_next(iter)
```

### Snapshot After Close

```elixir
alias TripleStore.Backend.RocksDB.NIF

db_path = System.tmp_dir!() <> "/ts_risk_" <> Integer.to_string(System.unique_integer([:positive]))
{:ok, db} = NIF.open(db_path)

NIF.put(db, :spo, "k1", "v1")
{:ok, snap} = NIF.snapshot(db)

NIF.close(db)

# Risky call
NIF.snapshot_get(snap, :spo, "k1")
```

If you see a VM crash or inconsistent behavior, that confirms the risk.

## Possible Fix Directions

1. **Prevent close while iterators/snapshots are alive**
   - Track active iterator/snapshot counts in `DbRef`.
   - If count > 0, return `{:error, :busy}` from `close/1`.

2. **Defer DB drop until resources are released**
   - Replace `Option<DB>` with `Arc<DB>` and keep a refcount.
   - Only drop the DB when the last iterator/snapshot is dropped.

3. **Invalidate resources on close**
   - Mark `DbRef` as closed and also set all iterators to `None`.
   - Make `iterator_next/1` return `{:error, :already_closed}` if DB is closed.

4. **Avoid unsafe lifetime extension**
   - Harder, but safest. Consider RocksDB APIs that allow safe lifetimes
     or refactor to keep DB in a shared Arc and avoid `transmute`.

## Takeaway

If the DB can be closed while iterators/snapshots are still live, the current
design can crash. Until this is addressed, callers should ensure iterators and
snapshots are fully consumed and closed before calling `close/1`.
