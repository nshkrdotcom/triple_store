Here is the comprehensive testing strategy blueprint for the implementation agent. It maps out the high-risk areas, the verification logic required, and the specific architectural components that need coverage.

### **Test Strategy Blueprint: TripleStore Full Stack**

**Philosophy:**

1. **Safety First:** Verify the Rust NIFs cannot crash the BEAM under any lifecycle misuse.
2. **Consistency:** Ensure the three indices (SPO, POS, OSP) and the two dictionaries (ID2Str, Str2ID) never drift apart.
3. **Isolation:** Prove that the test infrastructure (DB Pool) guarantees clean state between tests.

---

### **Phase 1: The "Crash-Proof" Suite (Rust NIF Safety)**

*Target: `native/rocksdb_nif/src/lib.rs` (specifically `SharedDb` and `DbRef` logic)*

**Objective:** Prove that the `Arc<SharedDb>` pattern successfully prevents `use-after-free` segfaults.

1. **Zombie Iterator Test**
* **Setup:** Open DB, write 100 keys, create a `PrefixIterator`.
* **Trigger:** Call `NIF.close(db)`. Verify `db_ref` is now invalid (returns `:error`).
* **Crucial Step:** Call `NIF.iterator_next(iter)`.
* **Expectation:** Must return `{:ok, ...}` or `:iterator_end`. **Must NOT crash.**
* **Cleanup:** Call `NIF.iterator_close(iter)`. Verify resources are finally released (via OS monitoring if possible, or simple non-crash).


2. **Orphaned Snapshot Test**
* **Setup:** Open DB, put `key1="A"`, create `Snapshot`.
* **Trigger:** Put `key1="B"`. Call `NIF.close(db)`.
* **Crucial Step:** Call `NIF.snapshot_get(snapshot, ...)` for `key1`.
* **Expectation:** Must return "A". The snapshot must hold the underlying RocksDB handle alive despite the explicit close.


3. **Race Condition: Close vs. Read**
* **Setup:** Spawn process A that reads randomly. Spawn process B that closes the DB.
* **Expectation:** Process A should receive `{:error, :already_closed}` gracefully, never a segfault.



---

### **Phase 2: The "Chaos" Suite (Concurrency & Locking)**

*Target: `TripleStore.Dictionary.Manager` (GenServer serialization) vs `NIF` (RwLocks)*

**Objective:** Stress test the boundary between Elixir serialization and Rust threading.

1. **Dictionary Serialization Stress**
* **Scenario:** 50 processes trying to `get_or_create_id` for the *same* new term simultaneously.
* **Verification:** Ensure `SequenceCounter` increments exactly **once**. All 50 processes receive the same ID.
* **Target:** `TripleStore.Dictionary.Manager.get_or_create_id/2`.


2. **Reader/Writer Starvation**
* **Scenario:**
* 1 Writer performing massive `mixed_batch` writes (triggering RocksDB write locks).
* 20 Readers performing `snapshot` and `iterator` scans.


* **Verification:** Readers must not timeout. Verify `DirtyCpu` scheduler usage keeps the BEAM responsive (check `Process.info(pid, :reductions)`).


3. **Pool Exhaustion (Infra Test)**
* **Scenario:** Request `System.schedulers_online() * 2` databases from `TripleStore.Test.DbPool`.
* **Verification:** The pool must queue the excess requests and serve them as databases are checked in. No deadlocks.



---

### **Phase 3: The "Truth" Suite (Property-Based Testing)**

*Target: `TripleStore.Index` and `TripleStore.Dictionary` logic*

**Objective:** Mathematically prove data consistency using `StreamData`.

1. **Property: The "Triangle" of Indices**
* **Generator:** Random triples `{s, p, o}`.
* **Action:** Insert triple.
* **Invariant:**
* Query `S??` (SPO index) must contain triple.
* Query `?P?` (POS index) must contain triple.
* Query `??O` (OSP index) must contain triple.
* Query `S?O` (OSP + Filter) must contain triple.


* *If one index misses, the store is corrupted.*


2. **Property: Dictionary Isomorphism**
* **Generator:** Random Unicode strings, localized strings, and edge-case URIs.
* **Invariant:** `term |> encode |> decode == term`.
* **Special Focus:**
* Strings > 16KB (Must error gracefully).
* URIs with null bytes (Must error).
* Inline Integers near  boundary (Check bit-packing logic).




3. **Property: Batch Atomicity**
* **Action:** `write_batch` with 1 valid op and 1 invalid op (e.g., invalid CF name).
* **Invariant:** **Nothing** is written. The batch must be all-or-nothing.



---

### **Phase 4: The "Scale" Suite (Resource & Limits)**

*Target: `SequenceCounter.ex` and Memory usage*

**Objective:** Verify behavior at the edges of the system's limits.

1. **Sequence Overflow Simulation (Whitebox Test)**
* **Technique:** Manually write a high value (e.g., `2^59 - 5`) into the `__seq_counter__` key in RocksDB using `NIF.put`.
* **Action:** Call `Dictionary.get_or_create_id` 10 times.
* **Verification:**
* Calls 1-5 succeed.
* Calls 6+ return `{:error, :sequence_overflow}`.
* Verify `atomics` rollback in `SequenceCounter.ex` prevented wrapping to 0.




2. **Memory Leak Detection**
* **Action:** Run a tight loop: `Open -> Write(1MB) -> Snapshot -> Iterator -> Close`. Repeat 10k times.
* **Verification:** Monitor OS-level RAM. If `Arc`s are leaking, RAM will spike. (Use `:erlang.memory()` and OS monitoring).



---

### **Phase 5: Implementation Directives for the Agent**

When writing the tests, follow these patterns:

1. **Use the Pool:** Always use `use TripleStore.PooledDbCase` unless specifically testing lifecycle open/close.
2. **Prefixing:** Even inside the pool, use the `prefix` variable provided by the setup block for key isolation.
3. **Wait for Async:** When testing concurrency (Phase 2), use `Task.yield_many` to ensure all processes complete before asserting state.
4. **No Flue:** Avoid `Process.sleep`. Use message passing or `Monitor` to wait for side effects (like GenServer flushes).
5. **RocksDB Options:** For tests, override standard RocksDB options to disable auto-compaction and set small write buffers (1MB) to force flush behavior early.
