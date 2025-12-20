# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a high-performance RDF triple store implementation in Elixir with the following goals:
- Persistent storage using RocksDB via Rustler NIFs
- Full SPARQL 1.1 support (including UPDATE)
- OWL 2 RL reasoning with forward-chaining materialization

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                    TripleStore Public API                     │
├───────────────┬──────────────────────┬───────────────────────┤
│ SPARQL Engine │   OWL 2 RL Reasoner  │   Transaction Mgr     │
│  (pure Elixir)│     (pure Elixir)    │    (GenServer)        │
├───────────────┴──────────────────────┴───────────────────────┤
│                    Index & Dictionary Layer                   │
│              (Elixir with NIF calls for I/O)                 │
├──────────────────────────────────────────────────────────────┤
│                    Rustler NIF Boundary                       │
├──────────────────────────────────────────────────────────────┤
│   Column Families: spo, pos, osp, id2str, str2id, derived    │
│                      RocksDB Instance                         │
└──────────────────────────────────────────────────────────────┘
```

### Storage Design

- **Dictionary encoding**: All URIs, blank nodes, and literals map to 64-bit integer IDs with type tagging
- **Triple indices**: SPO, POS, OSP indices (big-endian keys) provide O(log n) access for all pattern types
- **Inline encoding**: Numeric types (xsd:integer, xsd:decimal, xsd:dateTime) encoded directly without dictionary lookup

### Key Design Decisions

- NIFs for: RDF/SPARQL parsing, RocksDB storage, compression
- Pure Elixir for: query execution (must be preemptible), SPARQL algebra optimization, reasoning rule evaluation, transaction coordination
- Use dirty CPU schedulers (`#[rustler::nif(schedule = "DirtyCpu")]`) for NIF operations >1ms
- Leapfrog Triejoin algorithm for complex BGP queries with 4+ patterns
- Semi-naive evaluation for reasoning (process only delta from previous iteration)

## Development Phases

The implementation follows five phases documented in `notes/research/development-overview.md`:
1. Storage Foundation (RocksDB + Rustler, dictionary encoding, indices)
2. SPARQL Query Engine (parser NIF via spargebra, algebra compiler, iterator execution)
3. Advanced Query Processing (Leapfrog Triejoin, cost-based optimizer, SPARQL UPDATE)
4. OWL 2 RL Reasoning (rule compiler, semi-naive evaluation, incremental maintenance)
5. Production Hardening (benchmarking, RocksDB tuning, telemetry)

## Dependencies

Elixir dependencies:
- `rdf` - RDF parsing and data structures
- `rustler` - NIF compilation
- `flow` - Concurrent processing for bulk loading
- `telemetry` - Metrics

Rust dependencies (via Rustler):
- `rocksdb` - Storage backend
- `spargebra` - SPARQL parser (from Oxigraph)

## Build Commands

Once the project scaffolding is created:
```bash
mix deps.get          # Fetch dependencies
mix compile           # Compile (includes NIF compilation)
mix test              # Run tests
mix test path/to/test.exs:LINE  # Run single test
```
