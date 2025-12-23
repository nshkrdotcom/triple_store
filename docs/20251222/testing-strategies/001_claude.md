Looking at your codebase, you have a classic multi-layer system with some documented safety risks (particularly the iterator/snapshot lifetime issue). Here's a comprehensive testing strategy:

## Testing Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Test Layers                                   │
├─────────────────────────────────────────────────────────────────────┤
│  Layer 5: End-to-End / SPARQL Query Tests (future)                  │
├─────────────────────────────────────────────────────────────────────┤
│  Layer 4: Stress & Chaos Tests (concurrency, failure injection)     │
├─────────────────────────────────────────────────────────────────────┤
│  Layer 3: Property-Based Tests (invariants, round-trips)            │
├─────────────────────────────────────────────────────────────────────┤
│  Layer 2: Elixir Integration Tests (NIF boundary, full stack)       │
├─────────────────────────────────────────────────────────────────────┤
│  Layer 1: Rust Unit Tests (in-crate, no BEAM)                       │
└─────────────────────────────────────────────────────────────────────┘
```

## Layer 1: Rust Unit Tests

This is your **most critical gap**. Test the Rust code *before* it crosses the NIF boundary.

```rust
// native/rocksdb_nif/src/lib.rs - add at the bottom

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;
    
    fn setup_db() -> (TempDir, DB) {
        let tmp = TempDir::new().unwrap();
        let mut opts = Options::default();
        opts.create_if_missing(true);
        opts.create_missing_column_families(true);
        
        let cf_descriptors: Vec<ColumnFamilyDescriptor> = CF_NAMES
            .iter()
            .map(|name| ColumnFamilyDescriptor::new(*name, Options::default()))
            .collect();
        
        let db = DB::open_cf_descriptors(&opts, tmp.path(), cf_descriptors).unwrap();
        (tmp, db)
    }
    
    #[test]
    fn test_cf_names_valid() {
        // Ensure all CF names are non-empty and distinct
        let names: std::collections::HashSet<_> = CF_NAMES.iter().collect();
        assert_eq!(names.len(), CF_NAMES.len());
    }
    
    #[test]
    fn test_basic_put_get() {
        let (_tmp, db) = setup_db();
        let cf = db.cf_handle("spo").unwrap();
        
        db.put_cf(&cf, b"key1", b"value1").unwrap();
        let result = db.get_cf(&cf, b"key1").unwrap();
        assert_eq!(result, Some(b"value1".to_vec()));
    }
    
    #[test]
    fn test_iterator_prefix_bounds() {
        let (_tmp, db) = setup_db();
        let cf = db.cf_handle("spo").unwrap();
        
        // Insert keys with different prefixes
        db.put_cf(&cf, b"aaa1", b"").unwrap();
        db.put_cf(&cf, b"aaa2", b"").unwrap();
        db.put_cf(&cf, b"bbb1", b"").unwrap();
        
        let prefix = b"aaa";
        let iter = db.iterator_cf(&cf, IteratorMode::From(prefix, rocksdb::Direction::Forward));
        
        let keys: Vec<_> = iter
            .take_while(|r| r.as_ref().map(|(k, _)| k.starts_with(prefix)).unwrap_or(false))
            .filter_map(|r| r.ok())
            .map(|(k, _)| k.to_vec())
            .collect();
        
        assert_eq!(keys.len(), 2);
        assert!(keys.iter().all(|k| k.starts_with(prefix)));
    }
    
    #[test]
    fn test_snapshot_isolation() {
        let (_tmp, db) = setup_db();
        let cf = db.cf_handle("spo").unwrap();
        
        db.put_cf(&cf, b"key1", b"v1").unwrap();
        
        let snap = db.snapshot();
        
        // Modify after snapshot
        db.put_cf(&cf, b"key1", b"v2").unwrap();
        db.put_cf(&cf, b"key2", b"v3").unwrap();
        
        // Snapshot should see old state
        let mut read_opts = ReadOptions::default();
        read_opts.set_snapshot(&snap);
        
        let result = db.get_cf_opt(&cf, b"key1", &read_opts).unwrap();
        assert_eq!(result, Some(b"v1".to_vec()));
        
        let result2 = db.get_cf_opt(&cf, b"key2", &read_opts).unwrap();
        assert_eq!(result2, None); // Didn't exist at snapshot time
    }
    
    #[test]
    fn test_write_batch_atomicity() {
        let (_tmp, db) = setup_db();
        let cf = db.cf_handle("spo").unwrap();
        
        let mut batch = WriteBatch::default();
        batch.put_cf(&cf, b"k1", b"v1");
        batch.put_cf(&cf, b"k2", b"v2");
        batch.put_cf(&cf, b"k3", b"v3");
        
        db.write(batch).unwrap();
        
        // All should exist
        assert!(db.get_cf(&cf, b"k1").unwrap().is_some());
        assert!(db.get_cf(&cf, b"k2").unwrap().is_some());
        assert!(db.get_cf(&cf, b"k3").unwrap().is_some());
    }
}
```

**Add to Cargo.toml:**
```toml
[dev-dependencies]
tempfile = "3.10"
```

**Run with:** `cd native/rocksdb_nif && cargo test`

---

## Layer 2: NIF Boundary Integration Tests

These test the Elixir ↔ Rust interface specifically.

```elixir
# test/triple_store/backend/rocksdb/nif_boundary_test.exs
defmodule TripleStore.Backend.RocksDB.NIFBoundaryTest do
  @moduledoc """
  Tests for NIF boundary safety and resource lifecycle.
  These tests specifically target the Rust/Elixir interface.
  """
  use ExUnit.Case, async: false  # Not async - we're testing resource lifecycle
  
  alias TripleStore.Backend.RocksDB.NIF
  alias TripleStore.TestHelpers
  
  describe "resource lifecycle" do
    test "iterator survives db close (Arc<SharedDb> keeps DB alive)" do
      # This tests the fix documented in rocksdb-close-lifetime-risk.md
      path = TestHelpers.test_db_path("lifecycle_iter")
      {:ok, db} = NIF.open(path)
      
      NIF.put(db, :spo, "key1", "value1")
      NIF.put(db, :spo, "key2", "value2")
      
      {:ok, iter} = NIF.prefix_iterator(db, :spo, "")
      
      # Close DB while iterator is alive
      :ok = NIF.close(db)
      
      # Iterator should still work because Arc<SharedDb> keeps DB alive
      {:ok, k1, _v1} = NIF.iterator_next(iter)
      assert k1 == "key1"
      
      {:ok, k2, _v2} = NIF.iterator_next(iter)
      assert k2 == "key2"
      
      :iterator_end = NIF.iterator_next(iter)
      
      NIF.iterator_close(iter)
      TestHelpers.cleanup_test_db(path)
    end
    
    test "snapshot survives db close" do
      path = TestHelpers.test_db_path("lifecycle_snap")
      {:ok, db} = NIF.open(path)
      
      NIF.put(db, :spo, "key1", "original")
      {:ok, snap} = NIF.snapshot(db)
      
      # Close DB
      :ok = NIF.close(db)
      
      # Snapshot should still work
      {:ok, value} = NIF.snapshot_get(snap, :spo, "key1")
      assert value == "original"
      
      NIF.release_snapshot(snap)
      TestHelpers.cleanup_test_db(path)
    end
    
    test "closed db returns already_closed for new operations" do
      path = TestHelpers.test_db_path("lifecycle_closed")
      {:ok, db} = NIF.open(path)
      :ok = NIF.close(db)
      
      assert {:error, :already_closed} = NIF.get(db, :spo, "key")
      assert {:error, :already_closed} = NIF.put(db, :spo, "key", "value")
      assert {:error, :already_closed} = NIF.prefix_iterator(db, :spo, "")
      assert {:error, :already_closed} = NIF.snapshot(db)
      assert {:error, :already_closed} = NIF.close(db)
      
      TestHelpers.cleanup_test_db(path)
    end
    
    test "iterator close is idempotent" do
      path = TestHelpers.test_db_path("iter_idempotent")
      {:ok, db} = NIF.open(path)
      
      {:ok, iter} = NIF.prefix_iterator(db, :spo, "")
      :ok = NIF.iterator_close(iter)
      {:error, :iterator_closed} = NIF.iterator_close(iter)
      
      NIF.close(db)
      TestHelpers.cleanup_test_db(path)
    end
    
    test "snapshot release is idempotent" do
      path = TestHelpers.test_db_path("snap_idempotent")
      {:ok, db} = NIF.open(path)
      
      {:ok, snap} = NIF.snapshot(db)
      :ok = NIF.release_snapshot(snap)
      {:error, :snapshot_released} = NIF.release_snapshot(snap)
      
      NIF.close(db)
      TestHelpers.cleanup_test_db(path)
    end
  end
  
  describe "column family validation" do
    test "invalid column family returns error" do
      path = TestHelpers.test_db_path("invalid_cf")
      {:ok, db} = NIF.open(path)
      
      assert {:error, {:invalid_cf, :nonexistent}} = NIF.get(db, :nonexistent, "key")
      assert {:error, {:invalid_cf, :nonexistent}} = NIF.put(db, :nonexistent, "k", "v")
      assert {:error, {:invalid_cf, :nonexistent}} = NIF.prefix_iterator(db, :nonexistent, "")
      
      NIF.close(db)
      TestHelpers.cleanup_test_db(path)
    end
    
    test "all documented column families work" do
      path = TestHelpers.test_db_path("all_cfs")
      {:ok, db} = NIF.open(path)
      
      for cf <- [:id2str, :str2id, :spo, :pos, :osp, :derived] do
        :ok = NIF.put(db, cf, "test_key", "test_value")
        {:ok, "test_value"} = NIF.get(db, cf, "test_key")
      end
      
      NIF.close(db)
      TestHelpers.cleanup_test_db(path)
    end
  end
  
  describe "binary handling" do
    test "handles empty binaries" do
      path = TestHelpers.test_db_path("empty_bin")
      {:ok, db} = NIF.open(path)
      
      :ok = NIF.put(db, :spo, "", "empty_key")
      :ok = NIF.put(db, :spo, "empty_value", "")
      :ok = NIF.put(db, :spo, "", "")
      
      {:ok, "empty_key"} = NIF.get(db, :spo, "")
      
      NIF.close(db)
      TestHelpers.cleanup_test_db(path)
    end
    
    test "handles large binaries" do
      path = TestHelpers.test_db_path("large_bin")
      {:ok, db} = NIF.open(path)
      
      # 1MB key and value
      large_key = :crypto.strong_rand_bytes(1_000_000)
      large_value = :crypto.strong_rand_bytes(1_000_000)
      
      :ok = NIF.put(db, :spo, large_key, large_value)
      {:ok, ^large_value} = NIF.get(db, :spo, large_key)
      
      NIF.close(db)
      TestHelpers.cleanup_test_db(path)
    end
    
    test "handles binary with null bytes" do
      path = TestHelpers.test_db_path("null_bytes")
      {:ok, db} = NIF.open(path)
      
      key_with_nulls = <<1, 0, 2, 0, 3>>
      value_with_nulls = <<0, 0, 0, "hello", 0, 0, 0>>
      
      :ok = NIF.put(db, :spo, key_with_nulls, value_with_nulls)
      {:ok, ^value_with_nulls} = NIF.get(db, :spo, key_with_nulls)
      
      NIF.close(db)
      TestHelpers.cleanup_test_db(path)
    end
  end
end
```

---

## Layer 3: Property-Based Tests

Use StreamData for invariants that must always hold.

```elixir
# test/triple_store/property_test.exs
defmodule TripleStore.PropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  
  alias TripleStore.Dictionary
  alias TripleStore.Index
  
  describe "Dictionary ID encoding" do
    property "encode_id/decode_id round-trips for all valid inputs" do
      check all type <- member_of(1..6),
                seq <- positive_integer(),
                seq <= Dictionary.max_sequence() do
        id = Dictionary.encode_id(type, seq)
        {decoded_type, decoded_seq} = Dictionary.decode_id(id)
        
        expected_type = case type do
          1 -> :uri
          2 -> :bnode
          3 -> :literal
          4 -> :integer
          5 -> :decimal
          6 -> :datetime
        end
        
        assert decoded_type == expected_type
        assert decoded_seq == seq
      end
    end
    
    property "inline integer encoding round-trips" do
      check all value <- integer(Dictionary.min_inline_integer()..Dictionary.max_inline_integer()) do
        {:ok, id} = Dictionary.encode_integer(value)
        {:ok, decoded} = Dictionary.decode_integer(id)
        assert decoded == value
      end
    end
    
    property "inline datetime encoding round-trips (post-epoch)" do
      check all ms <- positive_integer(),
                ms <= 253_402_300_799_000 do  # ~year 9999
        dt = DateTime.from_unix!(ms, :millisecond)
        {:ok, id} = Dictionary.encode_datetime(dt)
        {:ok, decoded} = Dictionary.decode_datetime(id)
        
        # Compare milliseconds (precision is milliseconds)
        assert DateTime.to_unix(decoded, :millisecond) == ms
      end
    end
    
    property "inline decimal encoding round-trips for small values" do
      check all coef <- integer(0..@max_decimal_mantissa),
                exp <- integer(-1023..1024),
                sign <- member_of([1, -1]) do
        decimal = %Decimal{sign: sign, coef: coef, exp: exp}
        
        if Dictionary.inline_encodable_decimal?(decimal) do
          {:ok, id} = Dictionary.encode_decimal(decimal)
          {:ok, decoded} = Dictionary.decode_decimal(id)
          assert Decimal.eq?(decoded, decimal)
        end
      end
    end
  end
  
  describe "Index key encoding" do
    @max_id (1 <<< 64) - 1
    
    property "SPO key encoding round-trips" do
      check all s <- integer(0..@max_id),
                p <- integer(0..@max_id),
                o <- integer(0..@max_id) do
        key = Index.spo_key(s, p, o)
        {ds, dp, d_o} = Index.decode_spo_key(key)
        
        assert {ds, dp, d_o} == {s, p, o}
      end
    end
    
    property "POS key encoding round-trips" do
      check all p <- integer(0..@max_id),
                o <- integer(0..@max_id),
                s <- integer(0..@max_id) do
        key = Index.pos_key(p, o, s)
        {dp, d_o, ds} = Index.decode_pos_key(key)
        
        assert {dp, d_o, ds} == {p, o, s}
      end
    end
    
    property "key_to_triple returns canonical SPO order from any index" do
      check all s <- integer(0..@max_id),
                p <- integer(0..@max_id),
                o <- integer(0..@max_id) do
        spo_key = Index.spo_key(s, p, o)
        pos_key = Index.pos_key(p, o, s)
        osp_key = Index.osp_key(o, s, p)
        
        assert Index.key_to_triple(:spo, spo_key) == {s, p, o}
        assert Index.key_to_triple(:pos, pos_key) == {s, p, o}
        assert Index.key_to_triple(:osp, osp_key) == {s, p, o}
      end
    end
    
    property "index keys preserve lexicographic ordering" do
      # Big-endian encoding ensures numeric order = lexicographic order
      check all s1 <- integer(0..@max_id),
                s2 <- integer(0..@max_id),
                p <- integer(0..@max_id),
                o <- integer(0..@max_id) do
        key1 = Index.spo_key(s1, p, o)
        key2 = Index.spo_key(s2, p, o)
        
        if s1 < s2 do
          assert key1 < key2
        else if s1 > s2 do
          assert key1 > key2
        else
          assert key1 == key2
        end
        end
      end
    end
  end
  
  describe "Index pattern selection" do
    property "select_index always returns valid index" do
      check all s_bound <- boolean(),
                p_bound <- boolean(),
                o_bound <- boolean(),
                s <- integer(0..@max_id),
                p <- integer(0..@max_id),
                o <- integer(0..@max_id) do
        pattern = {
          if(s_bound, do: {:bound, s}, else: :var),
          if(p_bound, do: {:bound, p}, else: :var),
          if(o_bound, do: {:bound, o}, else: :var)
        }
        
        result = Index.select_index(pattern)
        
        assert result.index in [:spo, :pos, :osp]
        assert is_binary(result.prefix)
        assert is_boolean(result.needs_filter)
      end
    end
  end
end
```

**Add to mix.exs:**
```elixir
{:stream_data, "~> 1.0", only: [:test, :dev]}
```

---

## Layer 4: Stress & Concurrency Tests

```elixir
# test/triple_store/stress_test.exs
defmodule TripleStore.StressTest do
  use ExUnit.Case, async: false
  
  alias TripleStore.Backend.RocksDB.NIF
  alias TripleStore.Index
  alias TripleStore.TestHelpers
  
  @moduletag :stress
  @moduletag timeout: 120_000
  
  describe "concurrent reads" do
    test "100 parallel readers don't crash" do
      path = TestHelpers.test_db_path("stress_readers")
      {:ok, db} = NIF.open(path)
      
      # Seed data
      for i <- 1..1000 do
        key = "key_#{String.pad_leading(Integer.to_string(i), 6, "0")}"
        NIF.put(db, :spo, key, "value_#{i}")
      end
      
      # Launch 100 concurrent readers
      tasks = for _ <- 1..100 do
        Task.async(fn ->
          for _ <- 1..100 do
            i = :rand.uniform(1000)
            key = "key_#{String.pad_leading(Integer.to_string(i), 6, "0")}"
            {:ok, _} = NIF.get(db, :spo, key)
          end
          :ok
        end)
      end
      
      results = Task.await_many(tasks, 30_000)
      assert Enum.all?(results, &(&1 == :ok))
      
      NIF.close(db)
      TestHelpers.cleanup_test_db(path)
    end
    
    test "concurrent iterators don't interfere" do
      path = TestHelpers.test_db_path("stress_iterators")
      {:ok, db} = NIF.open(path)
      
      # Seed data with different prefixes
      for prefix <- ["a", "b", "c", "d", "e"] do
        for i <- 1..100 do
          NIF.put(db, :spo, "#{prefix}_#{i}", "value")
        end
      end
      
      # Launch concurrent iterators
      tasks = for prefix <- ["a", "b", "c", "d", "e"], _ <- 1..10 do
        Task.async(fn ->
          {:ok, iter} = NIF.prefix_iterator(db, :spo, prefix)
          {:ok, results} = NIF.iterator_collect(iter)
          NIF.iterator_close(iter)
          
          # Verify all results have correct prefix
          assert length(results) == 100
          assert Enum.all?(results, fn {k, _v} -> String.starts_with?(k, prefix) end)
          :ok
        end)
      end
      
      results = Task.await_many(tasks, 30_000)
      assert Enum.all?(results, &(&1 == :ok))
      
      NIF.close(db)
      TestHelpers.cleanup_test_db(path)
    end
  end
  
  describe "concurrent writes" do
    test "100 parallel writers with disjoint keys" do
      path = TestHelpers.test_db_path("stress_writers")
      {:ok, db} = NIF.open(path)
      
      tasks = for worker_id <- 1..100 do
        Task.async(fn ->
          for i <- 1..100 do
            key = "worker_#{worker_id}_key_#{i}"
            :ok = NIF.put(db, :spo, key, "value_#{i}")
          end
          :ok
        end)
      end
      
      results = Task.await_many(tasks, 60_000)
      assert Enum.all?(results, &(&1 == :ok))
      
      # Verify all writes succeeded
      for worker_id <- 1..100, i <- 1..100 do
        key = "worker_#{worker_id}_key_#{i}"
        {:ok, _} = NIF.get(db, :spo, key)
      end
      
      NIF.close(db)
      TestHelpers.cleanup_test_db(path)
    end
    
    test "concurrent batch writes" do
      path = TestHelpers.test_db_path("stress_batch")
      {:ok, db} = NIF.open(path)
      
      tasks = for worker_id <- 1..50 do
        Task.async(fn ->
          for batch_num <- 1..20 do
            operations = for i <- 1..50 do
              key = "w#{worker_id}_b#{batch_num}_k#{i}"
              {:spo, key, "value"}
            end
            :ok = NIF.write_batch(db, operations)
          end
          :ok
        end)
      end
      
      results = Task.await_many(tasks, 60_000)
      assert Enum.all?(results, &(&1 == :ok))
      
      NIF.close(db)
      TestHelpers.cleanup_test_db(path)
    end
  end
  
  describe "snapshot isolation under concurrent writes" do
    test "snapshot sees consistent state despite ongoing writes" do
      path = TestHelpers.test_db_path("stress_snap_isolation")
      {:ok, db} = NIF.open(path)
      
      # Initial data
      for i <- 1..100 do
        NIF.put(db, :spo, "key_#{i}", "v0")
      end
      
      # Take snapshot
      {:ok, snap} = NIF.snapshot(db)
      
      # Start writers that update all keys
      writer_task = Task.async(fn ->
        for round <- 1..10 do
          for i <- 1..100 do
            NIF.put(db, :spo, "key_#{i}", "v#{round}")
          end
        end
        :ok
      end)
      
      # Meanwhile, repeatedly read from snapshot
      reader_results = for _ <- 1..1000 do
        i = :rand.uniform(100)
        {:ok, value} = NIF.snapshot_get(snap, :spo, "key_#{i}")
        value
      end
      
      Task.await(writer_task, 30_000)
      
      # All snapshot reads should have seen original value
      assert Enum.all?(reader_results, &(&1 == "v0"))
      
      NIF.release_snapshot(snap)
      NIF.close(db)
      TestHelpers.cleanup_test_db(path)
    end
  end
  
  describe "index consistency" do
    test "triple indices stay consistent under concurrent writes" do
      path = TestHelpers.test_db_path("stress_index")
      {:ok, db} = NIF.open(path)
      
      # Concurrent triple insertions
      tasks = for worker <- 1..20 do
        Task.async(fn ->
          for i <- 1..100 do
            s = worker * 1000 + i
            p = :rand.uniform(10)
            o = :rand.uniform(100)
            
            :ok = Index.insert_triple(db, {s, p, o})
          end
          :ok
        end)
      end
      
      Task.await_many(tasks, 60_000)
      
      # Verify index consistency: for each SPO entry, POS and OSP should exist
      {:ok, spo_stream} = NIF.prefix_stream(db, :spo, <<>>)
      
      inconsistencies = spo_stream
      |> Stream.map(fn {spo_key, _} ->
        {s, p, o} = Index.decode_spo_key(spo_key)
        
        pos_key = Index.pos_key(p, o, s)
        osp_key = Index.osp_key(o, s, p)
        
        pos_exists = NIF.exists(db, :pos, pos_key)
        osp_exists = NIF.exists(db, :osp, osp_key)
        
        {pos_exists, osp_exists}
      end)
      |> Enum.reject(fn {{:ok, pos}, {:ok, osp}} -> pos and osp; _ -> false end)
      |> Enum.to_list()
      
      assert inconsistencies == [], "Found #{length(inconsistencies)} index inconsistencies"
      
      NIF.close(db)
      TestHelpers.cleanup_test_db(path)
    end
  end
end
```

---

## Layer 5: Full Stack Integration Test

```elixir
# test/triple_store/integration/full_stack_test.exs
defmodule TripleStore.Integration.FullStackTest do
  @moduledoc """
  End-to-end tests that exercise the complete stack:
  RDF terms → Dictionary → Index → RocksDB → Index → Dictionary → RDF terms
  """
  use ExUnit.Case, async: false
  
  alias TripleStore.Adapter
  alias TripleStore.Backend.RocksDB.NIF
  alias TripleStore.Dictionary.Manager
  alias TripleStore.Index
  alias TripleStore.TestHelpers
  
  setup do
    path = TestHelpers.test_db_path("full_stack")
    {:ok, db} = NIF.open(path)
    {:ok, manager} = Manager.start_link(db: db)
    
    on_exit(fn ->
      Manager.stop(manager)
      NIF.close(db)
      TestHelpers.cleanup_test_db(path)
    end)
    
    {:ok, db: db, manager: manager}
  end
  
  describe "complete round-trip" do
    test "RDF triple survives full encode/store/retrieve/decode cycle", ctx do
      # Create RDF terms
      subject = RDF.iri("http://example.org/subject")
      predicate = RDF.iri("http://example.org/predicate")
      object = RDF.literal("Hello, World!")
      
      # Encode to IDs
      {:ok, s_id} = Adapter.term_to_id(ctx.manager, subject)
      {:ok, p_id} = Adapter.term_to_id(ctx.manager, predicate)
      {:ok, o_id} = Adapter.term_to_id(ctx.manager, object)
      
      # Store in index
      :ok = Index.insert_triple(ctx.db, {s_id, p_id, o_id})
      
      # Query back
      {:ok, [{^s_id, ^p_id, ^o_id}]} = Index.lookup_all(ctx.db, {{:bound, s_id}, :var, :var})
      
      # Decode back to RDF
      {:ok, decoded_s} = Adapter.id_to_term(ctx.db, s_id)
      {:ok, decoded_p} = Adapter.id_to_term(ctx.db, p_id)
      {:ok, decoded_o} = Adapter.id_to_term(ctx.db, o_id)
      
      assert decoded_s == subject
      assert decoded_p == predicate
      assert RDF.Literal.value(decoded_o) == "Hello, World!"
    end
    
    test "inline-encoded literals don't hit dictionary", ctx do
      subject = RDF.iri("http://example.org/thing")
      predicate = RDF.iri("http://example.org/count")
      object = RDF.literal(42)  # Inline-encodable integer
      
      {:ok, s_id} = Adapter.term_to_id(ctx.manager, subject)
      {:ok, p_id} = Adapter.term_to_id(ctx.manager, predicate)
      {:ok, o_id} = Adapter.term_to_id(ctx.manager, object)
      
      # Object should be inline-encoded (no dictionary entry)
      assert TripleStore.Dictionary.inline_encoded?(o_id)
      
      # Round-trip should still work
      {:ok, decoded} = Adapter.id_to_term(ctx.db, o_id)
      assert RDF.Literal.value(decoded) == 42
    end
    
    test "all pattern queries work correctly", ctx do
      # Insert test data: person1 knows person2, person1 likes pizza
      p1 = RDF.iri("http://ex.org/person1")
      p2 = RDF.iri("http://ex.org/person2")
      knows = RDF.iri("http://ex.org/knows")
      likes = RDF.iri("http://ex.org/likes")
      pizza = RDF.iri("http://ex.org/pizza")
      
      {:ok, [p1_id, p2_id, knows_id, likes_id, pizza_id]} =
        Adapter.terms_to_ids(ctx.manager, [p1, p2, knows, likes, pizza])
      
      :ok = Index.insert_triple(ctx.db, {p1_id, knows_id, p2_id})
      :ok = Index.insert_triple(ctx.db, {p1_id, likes_id, pizza_id})
      
      # Test all pattern shapes
      
      # S?? - all triples about person1
      {:ok, s_results} = Index.lookup_all(ctx.db, {{:bound, p1_id}, :var, :var})
      assert length(s_results) == 2
      
      # SP? - what does person1 know?
      {:ok, sp_results} = Index.lookup_all(ctx.db, {{:bound, p1_id}, {:bound, knows_id}, :var})
      assert sp_results == [{p1_id, knows_id, p2_id}]
      
      # ?P? - who knows anyone?
      {:ok, p_results} = Index.lookup_all(ctx.db, {:var, {:bound, knows_id}, :var})
      assert p_results == [{p1_id, knows_id, p2_id}]
      
      # ?PO - who knows person2?
      {:ok, po_results} = Index.lookup_all(ctx.db, {:var, {:bound, knows_id}, {:bound, p2_id}})
      assert po_results == [{p1_id, knows_id, p2_id}]
      
      # ??O - all triples with pizza as object
      {:ok, o_results} = Index.lookup_all(ctx.db, {:var, :var, {:bound, pizza_id}})
      assert o_results == [{p1_id, likes_id, pizza_id}]
      
      # S?O - how is person1 related to pizza? (requires filtering)
      {:ok, so_results} = Index.lookup_all(ctx.db, {{:bound, p1_id}, :var, {:bound, pizza_id}})
      assert so_results == [{p1_id, likes_id, pizza_id}]
      
      # ??? - all triples
      {:ok, all_results} = Index.lookup_all(ctx.db, {:var, :var, :var})
      assert length(all_results) == 2
    end
  end
end
```

---

## Test Configuration

**test/test_helper.exs:**
```elixir
ExUnit.start(exclude: [:stress])

# Load support modules
Code.require_file("support/test_helpers.ex", __DIR__)
```

**Running tests:**
```bash
# Normal test run (excludes stress tests)
mix test

# Include stress tests
mix test --include stress

# Run only stress tests
mix test --only stress

# Run Rust tests
cd native/rocksdb_nif && cargo test

# Run all tests with coverage
mix test --cover
```

---

## Summary: Test Coverage Matrix

| Component | Unit | Integration | Property | Stress |
|-----------|------|-------------|----------|--------|
| Rust/RocksDB | cargo test | | | |
| NIF boundary | | ✓ lifecycle tests | | |
| Dictionary encoding | | | ✓ round-trips | |
| Index encoding | | | ✓ round-trips | |
| Index consistency | | | ✓ ordering | ✓ concurrent writes |
| Snapshot isolation | | ✓ | | ✓ under writes |
| Resource lifecycle | | ✓ close semantics | | |
| Full stack | | ✓ RDF round-trip | | |

This gives you confidence at each layer, with the Rust unit tests as your foundation and property tests ensuring invariants hold across the input space.
