Based on the comprehensive context provided—specifically the architectural split between Elixir/Rustler/RocksDB and the identified "Lifetime Risk"—here is a sound, comprehensive testing strategy.

This strategy moves beyond standard unit tests to target the specific risks of NIFs: **Memory Safety**, **BEAM Stability**, and **Data Consistency**.

---

### 1. The "Red Line" Test Suite: Safety & Lifetimes

**Goal:** Verify the fix for the `use-after-free` risk identified in `docs/20251222/rocksdb-close-lifetime-risk.md`. If this fails, the BEAM crashes.

Since you implemented the `Arc<SharedDb>` pattern in Rust, you must prove that the database handle outlives the Elixir reference.

**The Strategy:**
Create a `LifecycleSafetyTest` module that explicitly attempts to trigger Segfaults.

* **Test Case A: Iterator Survival**
1. Open DB.
2. Write data.
3. Open an Iterator.
4. **Close the DB** (Elixir side `NIF.close/1`).
5. Attempt to read from the Iterator.


* *Expectation:* It must succeed (or error gracefully), NOT crash the VM. The Rust `Arc` count should keep the underlying RocksDB alive.


* **Test Case B: Snapshot Isolation**
1. Open DB.
2. Put "A".
3. Take Snapshot.
4. Put "B" (overwrite "A").
5. **Close the DB**.
6. Read from Snapshot.


* *Expectation:* Return "A". The snapshot must hold a reference to the dropped DB.



### 2. Property-Based Testing (StreamData)

**Goal:** Exhaustive coverage of the TripleStore logic (Encoding + Indexing) without writing manual cases for every edge case.

**The Strategy:**
Use `StreamData` to generate random RDF terms and triples.

* **Property: Encoding Reversibility**
* Generate random RDF terms (URIs, BNodes, Literals with weird unicode/languages).
* Assert `term |> encode |> decode == term`.
* *Specific focus:* Boundary checks on the dictionary ID limits (e.g., verify that `inline_encoded?` logic handles the exact bit boundaries of 2^59).


* **Property: Index Consistency (The "Triangle" Test)**
* Generate a list of random triples.
* Insert them.
* Select a random Triple `T = {s, p, o}` from the set.
* Assert that querying `S??`, `?P?`, `??O`, and `S?O` *all* return `T`.
* *Why:* This validates that `SPO`, `POS`, and `OSP` indices are perfectly synchronized by the atomic `write_batch` in Rust.



**Example Elixir Code:**

```elixir
check all s <- rdf_iri(), p <- rdf_iri(), o <- rdf_literal() do
  :ok = TripleStore.add(db, {s, p, o})
  # Test atomic write to all indices
  assert TripleStore.query(db, {s, :var, :var}) |> Enum.member?({s, p, o}) # SPO
  assert TripleStore.query(db, {:var, p, :var}) |> Enum.member?({s, p, o}) # POS
  assert TripleStore.query(db, {:var, :var, o}) |> Enum.member?({s, p, o}) # OSP
end

```

### 3. Concurrency "Torture" Testing

**Goal:** Ensure the Rustler NIFs (using `RwLock` and `Mutex`) don't deadlock or corrupt data under high concurrency.

**The Strategy:**

* **Reader/Writer Race:** Spawn 1 writer process continuously updating a key, and 10 reader processes continuously reading it via Snapshots and Iterators.
* **Pool Exhaustion:** If using the `DbPool` (from your optimization docs), create a test that requests `pool_size + 1` databases to verify queuing logic works and doesn't timeout or deadlock.

### 4. Dictionary Sequence Overflow Simulation

**Goal:** Test the logic in `SequenceCounter.ex` and `dictionary.ex`.

**The Strategy:**
You cannot generate 2^59 IDs in a test. However, you can mock the state or use a "Whitebox" test approach.

* **Mock State:** Manually inject a counter value near the limit (e.g., `2^59 - 5`) into the RocksDB `str2id` key `__seq_counter__uri`.
* **Action:** Call `next_id`.
* **Expectation:** It should succeed 5 times, then return `{:error, :sequence_overflow}`. This validates the `atomics` rollback logic in `SequenceCounter.ex`.

### 5. Leak Detection (The "Long Run")

**Goal:** Ensure `ResourceArc`s are actually dropped.

**The Strategy:**

* Run a test loop 100,000 times: Open DB -> Write -> Scan -> Close.
* Monitor OS-level open file descriptors (RocksDB uses many FDs) and memory usage.
* If FDs climb steadily, the Rust `Drop` trait isn't firing correctly, meaning your `Arc`s are leaking.

### 6. Integration of Performance Fixes

**Goal:** Ensure the test suite itself remains fast (as per your optimization analysis).

* **Mandatory:** Apply the `solution-db-pool.md` strategy.
* **Why:** You cannot run the "Torture Tests" or "Property Tests" efficiently if every case takes 30ms to boot RocksDB. The pool reduces this to <1ms, allowing you to run thousands of property iterations.

### Summary Checklist

| Component | Test Strategy | Tooling |
| --- | --- | --- |
| **Rust Safety** | Lifecycle tests (Close vs Iterator) | `ExUnit` (Manual sequence) |
| **Encodings** | Reversibility checks | `StreamData` |
| **Indices** | Cross-index consistency | `StreamData` |
| **Concurrency** | Read/Write races | `Task.async_stream` |
| **Sequence Logic** | Boundary injection | Whitebox state injection |
| **Resources** | FD/Memory monitoring | `Observer` / CI scripts |

**Immediate Next Step:**
Would you like me to generate the **`LifecycleSafetyTest`** module code first? This targets the most critical risk (VM crashing due to use-after-free) documented in your context.
