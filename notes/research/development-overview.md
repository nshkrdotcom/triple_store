# Triple Store Implementation Phases

A phased roadmap for building a high-performance triple store in Elixir with RocksDB + Rustler as the foundational storage layer, supporting RDF/RDFS/OWL, full SPARQL 1.1 (including UPDATE), and OWL 2 RL reasoning.

---

## Phase 1: Storage Foundation with RocksDB + Rustler

**Goal:** Establish the persistent storage layer with dictionary encoding and triple indices.

### Deliverables

#### 1.1 Rustler NIF Wrapper for RocksDB

- Use `rox` as starting point or build custom wrapper with `rust-rocksdb` crate
- Configure column families: `id2str`, `str2id`, `spo`, `pos`, `osp`
- Implement dirty CPU scheduler annotations for operations >1ms
- WriteBatch API for atomic multi-index writes

```rust
#[rustler::nif(schedule = "DirtyCpu")]
fn open(path: String, opts: OpenOptions) -> Result<ResourceArc<DbRef>, Error> {
    let mut cf_opts = Options::default();
    cf_opts.create_if_missing(true);
    cf_opts.create_missing_column_families(true);
    
    let cfs = vec!["id2str", "str2id", "spo", "pos", "osp"];
    let db = DB::open_cf(&cf_opts, path, cfs)?;
    
    Ok(ResourceArc::new(DbRef(Arc::new(db))))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn put_batch(db: ResourceArc<DbRef>, operations: Vec<BatchOp>) -> Result<(), Error> {
    let mut batch = WriteBatch::default();
    for op in operations {
        let cf = db.cf_handle(&op.cf)?;
        batch.put_cf(cf, &op.key, &op.value);
    }
    db.write(batch)?;
    Ok(())
}
```

#### 1.2 Dictionary Encoding Module

- Type-tagged 64-bit IDs (URI, BNode, literals with inline numerics)
- Bidirectional lookup via `id2str` / `str2id` column families
- Sequence counter using RocksDB's merge operator or `:atomics`

```elixir
defmodule TripleStore.Dictionary do
  @type_uri      0b0001
  @type_bnode    0b0010
  @type_literal  0b0011
  @type_integer  0b0100  # Inline encoded
  @type_decimal  0b0101  # Inline encoded
  @type_datetime 0b0110  # Inline encoded
  
  def get_or_create_id(db, term) do
    case Backend.RocksDB.get(db, :str2id, encode_term(term)) do
      {:ok, id} -> decode_id(id)
      :not_found -> create_id(db, term)
    end
  end
  
  defp create_id(db, term) do
    seq = :atomics.add_get(id_counter(), 1, 1)
    id = encode_id(term_type(term), seq)
    
    Backend.RocksDB.put_batch(db, [
      {:str2id, encode_term(term), <<id::64>>},
      {:id2str, <<id::64>>, encode_term(term)}
    ])
    
    id
  end
  
  # Inline encoding for numeric types (no dictionary lookup needed)
  def encode_inline(:integer, n) when n >= 0 and n < (1 <<< 59) do
    (@type_integer <<< 60) ||| n
  end
end
```

#### 1.3 Index Layer

- SPO/POS/OSP key encoding (big-endian for natural ordering)
- Prefix iterator abstraction for pattern matching
- Basic insert/delete/lookup operations

```elixir
defmodule TripleStore.Index do
  def spo_key(s, p, o), do: <<s::64-big, p::64-big, o::64-big>>
  def pos_key(p, o, s), do: <<p::64-big, o::64-big, s::64-big>>
  def osp_key(o, s, p), do: <<o::64-big, s::64-big, p::64-big>>
  
  def insert_triple(db, {s, p, o}) do
    s_id = Dictionary.get_or_create_id(db, s)
    p_id = Dictionary.get_or_create_id(db, p)
    o_id = Dictionary.get_or_create_id(db, o)
    
    Backend.RocksDB.put_batch(db, [
      {:spo, spo_key(s_id, p_id, o_id), <<>>},
      {:pos, pos_key(p_id, o_id, s_id), <<>>},
      {:osp, osp_key(o_id, s_id, p_id), <<>>}
    ])
  end
  
  def lookup(db, pattern) do
    {cf, prefix} = pattern_to_index(pattern)
    
    db
    |> Backend.RocksDB.prefix_iterator(cf, prefix)
    |> Stream.map(&decode_triple/1)
  end
  
  defp pattern_to_index({:bound, :bound, :bound}), do: {:spo, ...}
  defp pattern_to_index({:bound, :bound, :var}),   do: {:spo, ...}
  defp pattern_to_index({:bound, :var, :var}),     do: {:spo, ...}
  defp pattern_to_index({:var, :bound, :bound}),   do: {:pos, ...}
  defp pattern_to_index({:var, :bound, :var}),     do: {:pos, ...}
  defp pattern_to_index({:var, :var, :bound}),     do: {:osp, ...}
  defp pattern_to_index({:bound, :var, :bound}),   do: {:osp, ...}  # Filter required
  defp pattern_to_index({:var, :var, :var}),       do: {:spo, <<>>} # Full scan
end
```

#### 1.4 RDF.ex Integration

- Adapter to convert `RDF.Triple` / `RDF.Graph` to internal representation
- Bulk loading pipeline with batched writes

```elixir
defmodule TripleStore.RDFAdapter do
  def load_graph(db, %RDF.Graph{} = graph) do
    graph
    |> RDF.Graph.triples()
    |> Stream.chunk_every(1000)
    |> Stream.each(fn batch ->
      operations = Enum.flat_map(batch, &triple_to_operations(db, &1))
      Backend.RocksDB.put_batch(db, operations)
    end)
    |> Stream.run()
  end
  
  defp triple_to_operations(db, {s, p, o}) do
    s_id = Dictionary.get_or_create_id(db, rdf_term_to_internal(s))
    p_id = Dictionary.get_or_create_id(db, rdf_term_to_internal(p))
    o_id = Dictionary.get_or_create_id(db, rdf_term_to_internal(o))
    
    [
      {:spo, Index.spo_key(s_id, p_id, o_id), <<>>},
      {:pos, Index.pos_key(p_id, o_id, s_id), <<>>},
      {:osp, Index.osp_key(o_id, s_id, p_id), <<>>}
    ]
  end
end
```

### Phase 1 Milestones

- [ ] RocksDB NIF compiles and opens database with column families
- [ ] Dictionary encodes/decodes URIs, blank nodes, and literals
- [ ] Inline encoding works for xsd:integer, xsd:decimal, xsd:dateTime
- [ ] Triple insert writes to all three indices atomically
- [ ] Prefix iterator returns correct results for all 8 triple patterns
- [ ] Bulk load 1M triples from RDF.ex graph in <30 seconds

---

## Phase 2: SPARQL Query Engine

**Goal:** Parse SPARQL, compile to physical plans, execute against RocksDB indices.

### Deliverables

#### 2.1 SPARQL Parser (Rustler NIF)

- Wrap existing Rust SPARQL parser (`spargebra` from Oxigraph)
- Return Elixir-native AST representation
- Handle SPARQL 1.1 full grammar including UPDATE

```rust
use spargebra::Query;

#[rustler::nif]
fn parse_query(sparql: String) -> Result<Term, Error> {
    let query = Query::parse(&sparql, None)?;
    query_to_elixir_ast(query)
}

#[rustler::nif]
fn parse_update(sparql: String) -> Result<Term, Error> {
    let update = Update::parse(&sparql, None)?;
    update_to_elixir_ast(update)
}
```

```elixir
defmodule TripleStore.SPARQL.Parser do
  use Rustler, otp_app: :triple_store, crate: "sparql_parser_nif"
  
  def parse_query(_sparql), do: :erlang.nif_error(:not_loaded)
  def parse_update(_sparql), do: :erlang.nif_error(:not_loaded)
end
```

#### 2.2 Algebra Compiler (Pure Elixir)

- Transform parsed AST to SPARQL algebra
- Rule-based optimizations: filter pushing, constant folding
- Pattern-to-index mapping

```elixir
defmodule TripleStore.SPARQL.Algebra do
  defstruct [:type, :children, :metadata]
  
  # Algebra node types
  # :bgp, :join, :left_join, :filter, :union, :graph, 
  # :extend, :project, :distinct, :order, :slice
  
  def from_ast({:select, vars, where, modifiers}) do
    where
    |> compile_where()
    |> apply_modifiers(modifiers)
    |> wrap_project(vars)
  end
  
  defp compile_where({:bgp, patterns}) do
    %Algebra{type: :bgp, children: patterns}
  end
  
  defp compile_where({:filter, expr, inner}) do
    %Algebra{type: :filter, children: [compile_where(inner)], metadata: %{expr: expr}}
  end
end

defmodule TripleStore.SPARQL.Optimizer do
  def optimize(algebra) do
    algebra
    |> push_filters_down()
    |> fold_constants()
    |> reorder_bgp_patterns()
  end
  
  defp push_filters_down(%Algebra{type: :filter, children: [child], metadata: %{expr: expr}}) do
    case try_push_filter(child, expr) do
      {:pushed, new_child} -> new_child
      :cannot_push -> %Algebra{type: :filter, children: [optimize(child)], metadata: %{expr: expr}}
    end
  end
end
```

#### 2.3 Iterator-Based Execution

- Index nested loop join for simple BGPs
- Merge join for sorted inputs
- `Stream`-based lazy evaluation with backpressure

```elixir
defmodule TripleStore.SPARQL.Executor do
  def execute(db, %Algebra{type: :bgp, children: patterns}) do
    execute_bgp(db, patterns)
  end
  
  def execute(db, %Algebra{type: :filter, children: [child], metadata: %{expr: expr}}) do
    child
    |> execute(db)
    |> Stream.filter(&evaluate_filter(expr, &1))
  end
  
  def execute(db, %Algebra{type: :project, children: [child], metadata: %{vars: vars}}) do
    child
    |> execute(db)
    |> Stream.map(&Map.take(&1, vars))
  end
  
  defp execute_bgp(db, patterns) do
    patterns
    |> Optimizer.order_by_selectivity(db)
    |> Enum.reduce(Stream.repeatedly(fn -> %{} end), fn pattern, bindings ->
      Stream.flat_map(bindings, &join_pattern(db, pattern, &1))
    end)
  end
  
  defp join_pattern(db, {s, p, o}, bindings) do
    # Substitute bound variables
    s_bound = substitute(s, bindings)
    p_bound = substitute(p, bindings)
    o_bound = substitute(o, bindings)
    
    {cf, prefix} = Index.pattern_to_index({bound?(s_bound), bound?(p_bound), bound?(o_bound)})
    
    db
    |> Backend.RocksDB.prefix_iterator(cf, build_prefix(s_bound, p_bound, o_bound, cf))
    |> Stream.filter(&matches?(s_bound, p_bound, o_bound, &1))
    |> Stream.map(&extend_bindings(s, p, o, &1, bindings))
  end
end
```

#### 2.4 Basic Query Optimization

- Variable counting heuristics for join ordering
- Statistics collection (predicate cardinalities)

```elixir
defmodule TripleStore.Statistics do
  def collect(db) do
    predicates = 
      db
      |> Backend.RocksDB.prefix_iterator(:pos, <<>>)
      |> Stream.map(fn {key, _} -> decode_predicate(key) end)
      |> Enum.frequencies()
    
    %{
      total_triples: count_triples(db),
      predicate_counts: predicates,
      distinct_subjects: count_distinct(db, :spo, :subject),
      distinct_objects: count_distinct(db, :osp, :object)
    }
  end
end

defmodule TripleStore.SPARQL.Optimizer do
  def order_by_selectivity(patterns, db) do
    stats = Statistics.get_cached(db)
    
    Enum.sort_by(patterns, fn pattern ->
      estimate_cardinality(pattern, stats)
    end)
  end
  
  defp estimate_cardinality({s, p, o}, stats) do
    base = stats.total_triples
    
    base
    |> maybe_apply_predicate_selectivity(p, stats)
    |> maybe_apply_subject_bound(s, stats)
    |> maybe_apply_object_bound(o, stats)
  end
end
```

### Phase 2 Milestones

- [ ] SPARQL parser NIF handles SELECT, CONSTRUCT, ASK, DESCRIBE
- [ ] Algebra compiler produces correct plans for nested queries
- [ ] Filter push-down optimization works correctly
- [ ] BGP execution returns correct results for all pattern types
- [ ] JOIN, OPTIONAL, UNION, FILTER all execute correctly
- [ ] Query benchmark: simple BGP <10ms on 1M triples

---

## Phase 3: Advanced Query Processing

**Goal:** Worst-case optimal joins and full SPARQL 1.1 UPDATE support.

### Deliverables

#### 3.1 Leapfrog Triejoin Implementation

- Multi-way join for complex BGPs (4+ patterns)
- Trie iterator abstraction over RocksDB prefix scans
- Benchmark against nested loop for various query shapes

```elixir
defmodule TripleStore.Query.LeapfrogTriejoin do
  defmodule TrieIterator do
    defstruct [:db, :cf, :prefix, :current, :exhausted]
    
    def seek(%TrieIterator{} = iter, target) do
      case Backend.RocksDB.seek(iter.db, iter.cf, iter.prefix, target) do
        {:ok, key, _value} -> %{iter | current: decode_key(key), exhausted: false}
        :end_of_range -> %{iter | exhausted: true}
      end
    end
    
    def current(%TrieIterator{current: current}), do: current
    def exhausted?(%TrieIterator{exhausted: ex}), do: ex
  end
  
  def leapfrog_join(iterators) do
    Stream.unfold(init_iterators(iterators), fn
      :done -> nil
      state -> leapfrog_step(state)
    end)
  end
  
  defp leapfrog_step(iterators) do
    # Find max value across all iterators
    max_val = iterators |> Enum.map(&TrieIterator.current/1) |> Enum.max()
    
    # Seek all iterators to max_val
    seeked = Enum.map(iterators, &TrieIterator.seek(&1, max_val))
    
    if Enum.any?(seeked, &TrieIterator.exhausted?/1) do
      {:done, :done}
    else
      values = Enum.map(seeked, &TrieIterator.current/1)
      
      if Enum.all?(values, &(&1 == max_val)) do
        # All iterators agree - emit result and advance
        advanced = Enum.map(seeked, &TrieIterator.next/1)
        {max_val, advanced}
      else
        # Continue leapfrogging
        leapfrog_step(seeked)
      end
    end
  end
end
```

#### 3.2 Cost-Based Optimizer

- Cardinality estimation with histograms
- DPccp algorithm for join enumeration
- Plan caching with invalidation on updates

```elixir
defmodule TripleStore.SPARQL.CostOptimizer do
  def optimize_join_order(patterns, stats) do
    n = length(patterns)
    
    if n <= 3 do
      # Small queries: exhaustive enumeration
      patterns
      |> permutations()
      |> Enum.min_by(&estimate_plan_cost(&1, stats))
    else
      # Larger queries: DPccp algorithm
      dp_connected_components(patterns, stats)
    end
  end
  
  defp dp_connected_components(patterns, stats) do
    # Dynamic programming over connected subgraph complements
    # Returns optimal join tree
    ...
  end
  
  defp estimate_plan_cost(ordered_patterns, stats) do
    {_final_card, total_cost} = 
      Enum.reduce(ordered_patterns, {1, 0}, fn pattern, {card_so_far, cost_so_far} ->
        pattern_card = estimate_cardinality(pattern, stats)
        join_cost = card_so_far * pattern_card  # Simplified cost model
        {min(card_so_far, pattern_card), cost_so_far + join_cost}
      end)
    
    total_cost
  end
end

defmodule TripleStore.Query.PlanCache do
  use GenServer
  
  def get_or_compute(query_hash, compute_fn) do
    case :ets.lookup(__MODULE__, query_hash) do
      [{^query_hash, plan, _timestamp}] -> plan
      [] ->
        plan = compute_fn.()
        :ets.insert(__MODULE__, {query_hash, plan, System.monotonic_time()})
        plan
    end
  end
  
  def invalidate_all do
    :ets.delete_all_objects(__MODULE__)
  end
end
```

#### 3.3 SPARQL UPDATE

- INSERT DATA / DELETE DATA / DELETE WHERE / INSERT WHERE
- Snapshot isolation via RocksDB snapshots
- Write serialization through coordinator process

```elixir
defmodule TripleStore.SPARQL.Update do
  def execute(db, {:insert_data, triples}) do
    Transaction.write(db, fn txn ->
      Enum.each(triples, &Index.insert_triple(txn, &1))
    end)
  end
  
  def execute(db, {:delete_data, triples}) do
    Transaction.write(db, fn txn ->
      Enum.each(triples, &Index.delete_triple(txn, &1))
    end)
  end
  
  def execute(db, {:delete_where, pattern}) do
    Transaction.write(db, fn txn ->
      # Read with snapshot, then delete
      snapshot = Backend.RocksDB.snapshot(txn)
      
      pattern
      |> Executor.execute_bgp(snapshot)
      |> Stream.each(&Index.delete_triple(txn, build_triple(&1, pattern)))
      |> Stream.run()
    end)
  end
  
  def execute(db, {:insert_where, insert_template, where_pattern}) do
    Transaction.write(db, fn txn ->
      snapshot = Backend.RocksDB.snapshot(txn)
      
      where_pattern
      |> Executor.execute_bgp(snapshot)
      |> Stream.each(fn bindings ->
        triple = instantiate_template(insert_template, bindings)
        Index.insert_triple(txn, triple)
      end)
      |> Stream.run()
    end)
  end
end

defmodule TripleStore.Transaction do
  use GenServer
  
  # Serialize all writes through single coordinator
  def write(db, fun) do
    GenServer.call(__MODULE__, {:write, db, fun}, :infinity)
  end
  
  def handle_call({:write, db, fun}, _from, state) do
    result = Backend.RocksDB.transaction(db, fun)
    PlanCache.invalidate_all()  # Invalidate query cache on writes
    {:reply, result, state}
  end
end
```

#### 3.4 Property Paths

- Recursive evaluation with cycle detection
- Materialized path indices for common patterns (optional)

```elixir
defmodule TripleStore.SPARQL.PropertyPath do
  def evaluate(db, subject, {:zero_or_more, predicate}, object) do
    # Transitive closure with cycle detection
    evaluate_closure(db, subject, predicate, object, MapSet.new())
  end
  
  def evaluate(db, subject, {:one_or_more, predicate}, object) do
    # At least one step
    db
    |> single_step(subject, predicate)
    |> Stream.flat_map(fn mid ->
      Stream.concat(
        [{subject, mid}],
        evaluate(db, mid, {:zero_or_more, predicate}, object)
      )
    end)
  end
  
  defp evaluate_closure(db, current, predicate, target, visited) do
    if MapSet.member?(visited, current) do
      []
    else
      visited = MapSet.put(visited, current)
      
      direct = if matches_target?(current, target), do: [{current}], else: []
      
      recursive =
        db
        |> single_step(current, predicate)
        |> Stream.flat_map(&evaluate_closure(db, &1, predicate, target, visited))
      
      Stream.concat(direct, recursive)
    end
  end
end
```

### Phase 3 Milestones

- [ ] Leapfrog Triejoin outperforms nested loop on star queries (5+ patterns)
- [ ] Cost-based optimizer selects good plans for complex queries
- [ ] Plan cache shows >90% hit rate on repeated queries
- [ ] All SPARQL UPDATE operations work correctly
- [ ] Transactions provide snapshot isolation
- [ ] Property paths handle cycles without infinite loops

---

## Phase 4: OWL 2 RL Reasoning

**Goal:** Forward-chaining reasoner with incremental materialization.

### Deliverables

#### 4.1 Rule Compiler

- Parse OWL axioms from ontology
- Generate Datalog-style rules for OWL 2 RL profile
- Store compiled rules in `persistent_term`

```elixir
defmodule TripleStore.Reasoner.RuleCompiler do
  @owl2rl_rules [
    # rdfs:subClassOf transitivity
    {:scm_sco, 
     [{:pattern, [?c1, :"rdfs:subClassOf", ?c2]}, 
      {:pattern, [?c2, :"rdfs:subClassOf", ?c3]}],
     {:pattern, [?c1, :"rdfs:subClassOf", ?c3]}},
    
    # Class membership through subclass
    {:cax_sco,
     [{:pattern, [?x, :"rdf:type", ?c1]},
      {:pattern, [?c1, :"rdfs:subClassOf", ?c2]}],
     {:pattern, [?x, :"rdf:type", ?c2]}},
    
    # Property domain
    {:prp_dom,
     [{:pattern, [?p, :"rdfs:domain", ?c]},
      {:pattern, [?x, ?p, ?y]}],
     {:pattern, [?x, :"rdf:type", ?c]}},
    
    # Property range
    {:prp_rng,
     [{:pattern, [?p, :"rdfs:range", ?c]},
      {:pattern, [?x, ?p, ?y]}],
     {:pattern, [?y, :"rdf:type", ?c]}},
    
    # Transitive property
    {:prp_trp,
     [{:pattern, [?p, :"rdf:type", :"owl:TransitiveProperty"]},
      {:pattern, [?x, ?p, ?y]},
      {:pattern, [?y, ?p, ?z]}],
     {:pattern, [?x, ?p, ?z]}},
    
    # Symmetric property
    {:prp_symp,
     [{:pattern, [?p, :"rdf:type", :"owl:SymmetricProperty"]},
      {:pattern, [?x, ?p, ?y]}],
     {:pattern, [?y, ?p, ?x]}},
    
    # Inverse properties
    {:prp_inv1,
     [{:pattern, [?p1, :"owl:inverseOf", ?p2]},
      {:pattern, [?x, ?p1, ?y]}],
     {:pattern, [?y, ?p2, ?x]}},
    
    # owl:sameAs transitivity
    {:eq_trans,
     [{:pattern, [?x, :"owl:sameAs", ?y]},
      {:pattern, [?y, :"owl:sameAs", ?z]}],
     {:pattern, [?x, :"owl:sameAs", ?z]}},
    
    # ... additional OWL 2 RL rules
  ]
  
  def compile(ontology) do
    # Filter rules to those applicable given ontology axioms
    applicable_rules = 
      @owl2rl_rules
      |> Enum.filter(&rule_applicable?(&1, ontology))
      |> Enum.map(&optimize_rule(&1, ontology))
    
    :persistent_term.put({__MODULE__, :rules}, applicable_rules)
    applicable_rules
  end
  
  defp rule_applicable?({_name, body, _head}, ontology) do
    # Check if ontology contains axioms that could trigger this rule
    Enum.any?(body, &pattern_could_match?(&1, ontology))
  end
end
```

#### 4.2 Semi-Naive Evaluation

- Delta-based iteration to fixpoint
- Parallel rule application via `Task.async_stream`
- Derived triples stored in separate column family (or flagged)

```elixir
defmodule TripleStore.Reasoner.SemiNaive do
  @derive_cf :derived  # Separate column family for inferred triples
  
  def materialize(db, rules) do
    # Initial delta is all explicit facts
    initial_delta = load_all_triples(db, :explicit)
    
    loop(db, rules, initial_delta, 0)
  end
  
  defp loop(db, _rules, delta, iteration) when map_size(delta) == 0 do
    Logger.info("Materialization complete after #{iteration} iterations")
    :ok
  end
  
  defp loop(db, rules, delta, iteration) do
    Logger.debug("Iteration #{iteration}: processing #{map_size(delta)} delta facts")
    
    # Apply all rules in parallel using delta
    new_derived =
      rules
      |> Task.async_stream(
        fn rule -> apply_rule(db, rule, delta) end,
        max_concurrency: System.schedulers_online(),
        timeout: :infinity
      )
      |> Enum.flat_map(fn {:ok, facts} -> facts end)
      |> MapSet.new()
    
    # Filter out already-known facts
    truly_new = filter_novel(db, new_derived)
    
    # Store new derived facts
    store_derived(db, truly_new)
    
    # Continue with new facts as delta
    loop(db, rules, truly_new, iteration + 1)
  end
  
  defp apply_rule(db, {_name, body_patterns, head_pattern}, delta) do
    # For semi-naive: at least one body pattern must match delta
    body_patterns
    |> Enum.with_index()
    |> Enum.flat_map(fn {pattern, idx} ->
      # This pattern matches against delta, others against full DB
      other_patterns = List.delete_at(body_patterns, idx)
      
      delta
      |> match_pattern(pattern)
      |> Stream.flat_map(fn bindings ->
        evaluate_remaining(db, other_patterns, bindings)
      end)
      |> Stream.map(&instantiate_head(head_pattern, &1))
    end)
    |> Enum.to_list()
  end
end
```

#### 4.3 Incremental Maintenance

- Backward/Forward algorithm for deletions
- Justification tracking (optional, for full retraction support)
- TBox/ABox separation with precomputed class hierarchy

```elixir
defmodule TripleStore.Reasoner.Incremental do
  # Backward/Forward deletion algorithm
  
  def delete_with_reasoning(db, triple) do
    # 1. Delete the explicit triple
    Index.delete_triple(db, triple)
    
    # 2. Backward phase: find all derived facts that depended on this triple
    potentially_invalid = backward_trace(db, triple)
    
    # 3. Forward phase: re-derive facts that have alternative justifications
    still_valid = 
      potentially_invalid
      |> Task.async_stream(&can_rederive?(db, &1))
      |> Enum.filter(fn {:ok, {_triple, valid}} -> valid end)
      |> Enum.map(fn {:ok, {triple, _}} -> triple end)
      |> MapSet.new()
    
    # 4. Delete facts that cannot be re-derived
    to_delete = MapSet.difference(potentially_invalid, still_valid)
    Enum.each(to_delete, &delete_derived(db, &1))
    
    # 5. Recursively check facts derived from deleted facts
    if MapSet.size(to_delete) > 0 do
      Enum.each(to_delete, &delete_with_reasoning(db, &1))
    end
  end
  
  defp backward_trace(db, triple) do
    # Find all rules where this triple appears in body
    # Return all facts derived using those rules with this triple
    ...
  end
  
  defp can_rederive?(db, derived_triple) do
    # Check if any rule can derive this triple from remaining facts
    rules = get_rules_for_head(derived_triple)
    
    Enum.any?(rules, fn rule ->
      has_complete_body_match?(db, rule, derived_triple)
    end)
  end
end

defmodule TripleStore.Reasoner.TBoxCache do
  # Precompute and cache class/property hierarchies
  
  def build(db, ontology) do
    class_hierarchy = compute_class_hierarchy(db, ontology)
    property_hierarchy = compute_property_hierarchy(db, ontology)
    
    :persistent_term.put({__MODULE__, :class_hierarchy}, class_hierarchy)
    :persistent_term.put({__MODULE__, :property_hierarchy}, property_hierarchy)
  end
  
  def superclasses(class) do
    hierarchy = :persistent_term.get({__MODULE__, :class_hierarchy})
    Map.get(hierarchy, class, MapSet.new())
  end
  
  def subclasses(class) do
    # Inverse lookup
    ...
  end
end
```

#### 4.4 Reasoning Configuration

- Toggle materialization on/off per graph
- Query-time backward chaining fallback for unmaterialized predicates

```elixir
defmodule TripleStore.Reasoner do
  defstruct [:mode, :profile, :enabled_rules]
  
  @type mode :: :materialized | :hybrid | :query_time
  @type profile :: :rdfs | :owl2rl | :owl2el | :custom
  
  def configure(opts \\ []) do
    %__MODULE__{
      mode: Keyword.get(opts, :mode, :materialized),
      profile: Keyword.get(opts, :profile, :owl2rl),
      enabled_rules: Keyword.get(opts, :rules, :all)
    }
  end
  
  def query_with_reasoning(db, config, query) do
    case config.mode do
      :materialized ->
        # All reasoning pre-computed, just query
        Executor.execute(db, query)
      
      :hybrid ->
        # Query explicit + derived, backward chain for missing
        query
        |> add_backward_chain_operators(config)
        |> Executor.execute(db)
      
      :query_time ->
        # Full backward chaining (slower but no materialization overhead)
        BackwardChainer.execute(db, query, config)
    end
  end
end
```

### Phase 4 Milestones

- [ ] Rule compiler generates correct Datalog from OWL 2 RL axioms
- [ ] Semi-naive evaluation reaches fixpoint correctly
- [ ] Parallel rule application shows linear speedup with cores
- [ ] LUBM benchmark: full materialization in <60 seconds for LUBM(1)
- [ ] Incremental delete correctly retracts dependent inferences
- [ ] TBox cache eliminates redundant hierarchy computations

---

## Phase 5: Production Hardening

**Goal:** Benchmark, optimize, and prepare for production embedding.

### Deliverables

#### 5.1 Benchmarking Suite

- LUBM and BSBM data generators
- Query latency percentiles (p50, p95, p99)
- Bulk load throughput measurement
- Memory profiling under load

```elixir
defmodule TripleStore.Benchmark do
  def run_bsbm(db, opts \\ []) do
    scale = Keyword.get(opts, :scale, 1000)
    warmup = Keyword.get(opts, :warmup, 100)
    iterations = Keyword.get(opts, :iterations, 1000)
    
    # Generate data
    data = BSBM.Generator.generate(scale)
    
    # Load
    {load_time, _} = :timer.tc(fn -> RDFAdapter.load_graph(db, data) end)
    
    # Warmup
    queries = BSBM.Queries.all()
    Enum.each(1..warmup, fn _ ->
      Enum.each(queries, &execute_query(db, &1))
    end)
    
    # Measure
    results = 
      queries
      |> Enum.map(fn query ->
        times = 
          1..iterations
          |> Enum.map(fn _ ->
            {time, _} = :timer.tc(fn -> execute_query(db, query) end)
            time
          end)
        
        %{
          query: query.name,
          p50: percentile(times, 50),
          p95: percentile(times, 95),
          p99: percentile(times, 99),
          mean: Enum.sum(times) / length(times)
        }
      end)
    
    %{
      load_time_ms: load_time / 1000,
      triple_count: scale * 1000,
      throughput: (scale * 1000) / (load_time / 1_000_000),
      query_results: results
    }
  end
end
```

#### 5.2 RocksDB Tuning

- Block cache sizing based on available RAM
- Compaction scheduling (rate limiting, off-peak hours)
- Compression algorithm selection (LZ4 for speed, Zstd for ratio)
- Column family-specific tuning (bloom filters for dictionary lookups)

```elixir
defmodule TripleStore.Config.RocksDB do
  def production_options(available_ram_gb) do
    block_cache_size = trunc(available_ram_gb * 0.4 * 1024 * 1024 * 1024)
    
    %{
      # Global options
      max_open_files: 5000,
      max_background_jobs: 4,
      bytes_per_sync: 1024 * 1024,
      
      # Block cache (shared across column families)
      block_cache_size: block_cache_size,
      
      # Column family specific
      column_families: %{
        # Dictionary lookups benefit from bloom filters
        "str2id" => %{
          bloom_filter_bits_per_key: 10,
          compression: :lz4,
          block_size: 4096
        },
        "id2str" => %{
          bloom_filter_bits_per_key: 10,
          compression: :lz4,
          block_size: 4096
        },
        
        # Index column families - optimize for range scans
        "spo" => %{
          compression: :lz4,
          block_size: 16384,  # Larger blocks for sequential access
          prefix_extractor: {:fixed, 8}  # Subject prefix
        },
        "pos" => %{
          compression: :lz4,
          block_size: 16384,
          prefix_extractor: {:fixed, 8}  # Predicate prefix
        },
        "osp" => %{
          compression: :lz4,
          block_size: 16384,
          prefix_extractor: {:fixed, 8}  # Object prefix
        },
        
        # Derived facts - may have different access patterns
        "derived" => %{
          compression: :zstd,  # Better compression for larger data
          block_size: 16384
        }
      },
      
      # Compaction
      compaction: %{
        style: :level,
        max_bytes_for_level_base: 256 * 1024 * 1024,
        max_bytes_for_level_multiplier: 10,
        rate_limit_mb_per_sec: 100  # Limit I/O impact
      }
    }
  end
end
```

#### 5.3 Query Caching

- Result cache for repeated queries
- Invalidation on relevant triple updates
- Cache warming on startup (optional)

```elixir
defmodule TripleStore.Query.Cache do
  use GenServer
  
  @max_entries 10_000
  @max_result_size 1000  # Don't cache huge results
  
  def get(query_hash) do
    case :ets.lookup(__MODULE__, query_hash) do
      [{^query_hash, results, _timestamp, _access_count}] ->
        :ets.update_counter(__MODULE__, query_hash, {4, 1})  # Increment access count
        {:hit, results}
      [] ->
        :miss
    end
  end
  
  def put(query_hash, results) when length(results) <= @max_result_size do
    # LRU eviction if at capacity
    if :ets.info(__MODULE__, :size) >= @max_entries do
      evict_lru()
    end
    
    :ets.insert(__MODULE__, {query_hash, results, System.monotonic_time(), 1})
  end
  def put(_query_hash, _results), do: :ok  # Don't cache large results
  
  def invalidate_for_predicate(predicate) do
    # Invalidate queries that touch this predicate
    :ets.foldl(fn {hash, _results, _ts, _count}, acc ->
      if query_uses_predicate?(hash, predicate) do
        :ets.delete(__MODULE__, hash)
      end
      acc
    end, :ok, __MODULE__)
  end
end
```

#### 5.4 Operational Tooling

- Backup/restore via RocksDB checkpoints
- Statistics exposure via Telemetry
- Health checks for compaction lag, cache hit rates

```elixir
defmodule TripleStore.Telemetry do
  def attach do
    :telemetry.attach_many(
      "triple-store-metrics",
      [
        [:triple_store, :query, :stop],
        [:triple_store, :insert, :stop],
        [:triple_store, :reasoning, :stop],
        [:triple_store, :cache, :hit],
        [:triple_store, :cache, :miss]
      ],
      &handle_event/4,
      nil
    )
  end
  
  def handle_event([:triple_store, :query, :stop], measurements, metadata, _config) do
    :prometheus_histogram.observe(
      :query_duration_microseconds,
      [metadata.query_type],
      measurements.duration
    )
  end
  
  # ... other handlers
end

defmodule TripleStore.HealthCheck do
  def check(db) do
    %{
      status: :healthy,
      metrics: %{
        triple_count: Statistics.triple_count(db),
        index_size_bytes: Backend.RocksDB.get_property(db, "rocksdb.total-sst-files-size"),
        cache_hit_rate: Query.Cache.hit_rate(),
        compaction_pending_bytes: Backend.RocksDB.get_property(db, "rocksdb.compaction-pending"),
        memory_usage: Backend.RocksDB.get_property(db, "rocksdb.estimate-table-readers-mem")
      },
      last_backup: Backup.last_successful(),
      reasoning_status: Reasoner.status(db)
    }
  end
end

defmodule TripleStore.Backup do
  def create(db, path) do
    Backend.RocksDB.create_checkpoint(db, path)
  end
  
  def restore(checkpoint_path, target_path) do
    File.cp_r!(checkpoint_path, target_path)
    Backend.RocksDB.open(target_path, [])
  end
  
  def schedule_periodic(db, interval_hours, backup_dir) do
    :timer.apply_interval(
      interval_hours * 60 * 60 * 1000,
      __MODULE__,
      :create,
      [db, Path.join(backup_dir, timestamp_path())]
    )
  end
end
```

#### 5.5 API Finalization

- Clean public API for embedding application
- Documentation and usage examples
- Hex package preparation

```elixir
defmodule TripleStore do
  @moduledoc """
  A high-performance RDF triple store with SPARQL 1.1 and OWL 2 RL reasoning.
  
  ## Quick Start
  
      {:ok, store} = TripleStore.open("./data")
      
      # Load RDF data
      TripleStore.load(store, "ontology.ttl")
      
      # Query with SPARQL
      results = TripleStore.query(store, "SELECT ?s WHERE { ?s a foaf:Person }")
      
      # Enable reasoning
      TripleStore.materialize(store, profile: :owl2rl)
  """
  
  defdelegate open(path, opts \\ []), to: TripleStore.Store
  defdelegate close(store), to: TripleStore.Store
  
  defdelegate load(store, path_or_graph), to: TripleStore.Loader
  defdelegate insert(store, triples), to: TripleStore.Writer
  defdelegate delete(store, triples), to: TripleStore.Writer
  
  defdelegate query(store, sparql), to: TripleStore.SPARQL
  defdelegate update(store, sparql), to: TripleStore.SPARQL
  
  defdelegate materialize(store, opts \\ []), to: TripleStore.Reasoner
  defdelegate reasoning_status(store), to: TripleStore.Reasoner
  
  defdelegate backup(store, path), to: TripleStore.Backup
  defdelegate restore(path), to: TripleStore.Backup
  
  defdelegate stats(store), to: TripleStore.Statistics
  defdelegate health(store), to: TripleStore.HealthCheck
end
```

### Phase 5 Milestones

- [ ] BSBM benchmark shows <50ms p95 for standard queries
- [ ] Bulk load achieves >100k triples/second
- [ ] Memory usage stable under sustained load (no leaks)
- [ ] RocksDB tuning documented with rationale
- [ ] Backup/restore works correctly
- [ ] Telemetry integration with Prometheus/Grafana
- [ ] API documentation complete with examples
- [ ] Hex package published (if open-sourcing)

---

## Architecture Overview

```
┌──────────────────────────────────────────────────────────────┐
│                    Embedding Application                      │
├──────────────────────────────────────────────────────────────┤
│                    TripleStore Public API                     │
│         (query/1, insert/1, delete/1, materialize/1)         │
├───────────────┬──────────────────────┬───────────────────────┤
│ SPARQL Engine │   OWL 2 RL Reasoner  │   Transaction Mgr     │
│  (pure Elixir)│     (pure Elixir)    │    (GenServer)        │
├───────────────┴──────────────────────┴───────────────────────┤
│                    Index & Dictionary Layer                   │
│              (Elixir with NIF calls for I/O)                 │
├──────────────────────────────────────────────────────────────┤
│                    Rustler NIF Boundary                       │
├──────────────────────────────────────────────────────────────┤
│   ┌─────────┬─────────┬─────────┬──────────┬──────────┐      │
│   │  spo    │   pos   │   osp   │  id2str  │  str2id  │      │
│   │  (CF)   │  (CF)   │  (CF)   │   (CF)   │   (CF)   │      │
│   └─────────┴─────────┴─────────┴──────────┴──────────┘      │
│                      RocksDB Instance                         │
└──────────────────────────────────────────────────────────────┘
```

---

## Dependencies

```elixir
# mix.exs
defp deps do
  [
    # RDF parsing and data structures
    {:rdf, "~> 2.0"},
    
    # NIF compilation
    {:rustler, "~> 0.30"},
    {:rustler_precompiled, "~> 0.7"},
    
    # Concurrent processing
    {:flow, "~> 1.2"},
    
    # Telemetry
    {:telemetry, "~> 1.2"},
    {:telemetry_metrics, "~> 0.6"},
    {:telemetry_poller, "~> 1.0"},
    
    # Testing
    {:stream_data, "~> 0.6", only: [:test, :dev]},
    {:benchee, "~> 1.1", only: :dev}
  ]
end
```

```toml
# native/rocksdb_nif/Cargo.toml
[dependencies]
rustler = "0.30"
rocksdb = "0.21"
spargebra = "0.2"  # SPARQL parser from Oxigraph
```

