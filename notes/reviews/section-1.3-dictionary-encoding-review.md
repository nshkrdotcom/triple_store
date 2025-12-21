# Section 1.3 Dictionary Encoding - Comprehensive Review

**Date:** 2025-12-21
**Status:** PRE-IMPLEMENTATION REVIEW
**Scope:** Planning document analysis + codebase readiness assessment

---

## Executive Summary

Section 1.3 (Dictionary Encoding) is **NOT YET IMPLEMENTED**. The codebase contains only a stub module with type tag constants. This review analyzes the planning specification and codebase patterns to identify blockers, concerns, and recommendations before implementation begins.

**Key Findings:**
- Planning design is architecturally sound (85% complete)
- 0/12 required tests exist
- Several specification gaps need resolution before implementation
- Existing NIF layer provides solid foundation but has refactoring opportunities

---

## Implementation Status

| Task | Status | Notes |
|------|--------|-------|
| 1.3.1 Term ID Encoding | PARTIAL | Type tag constants only |
| 1.3.2 Sequence Counter | NOT STARTED | No implementation |
| 1.3.3 String-to-ID Mapping | NOT STARTED | No implementation |
| 1.3.4 ID-to-String Mapping | NOT STARTED | No implementation |
| 1.3.5 Inline Numeric Encoding | NOT STARTED | No implementation |
| 1.3.6 Unit Tests | NOT STARTED | 0/12 tests exist |

**Current Implementation:**
- `/lib/triple_store/dictionary.ex` (49 lines)
  - Type tag constants: `@type_uri`, `@type_bnode`, `@type_literal`, `@type_integer`, `@type_decimal`, `@type_datetime`
  - Accessor functions for each type tag
  - No encoding/decoding logic

---

## Findings by Category

### :rotating_light: Blockers (Must fix before implementation)

#### B1. Race Condition in Bidirectional Mapping
**Location:** Planning 1.3.3.3 (`get_or_create_id`)
**Risk:** CRITICAL - Data integrity
**Issue:** Between checking `str2id` and writing new ID, another process could create the same term, resulting in duplicate IDs for the same term.
**Resolution:** Implement atomic create-if-not-exists via:
1. Elixir-level GenServer mutex (simpler), OR
2. RocksDB-level compare-and-swap (requires NIF support)

#### B2. Inline Numeric Encoding Underspecified
**Location:** Planning 1.3.5
**Risk:** CRITICAL - Silent data corruption
**Issue:** Fixed-point decimal and datetime encoding lack precision specifications:
- How many decimal places for `xsd:decimal`?
- Seconds vs milliseconds for `xsd:dateTime`?
- Negative integer handling (two's complement)?
**Resolution:** Document exact encoding format before implementation:
```
xsd:integer: Signed 60-bit, range [-2^59, 2^59)
xsd:decimal: 48-bit mantissa + 12-bit exponent (TBD)
xsd:dateTime: Unix seconds since epoch, UTC normalized
```

#### B3. Sequence Counter Persistence Strategy Undefined
**Location:** Planning 1.3.2.3
**Risk:** HIGH - ID collision after crash
**Issue:** "Periodic persistence" mentioned but no specification for:
- Flush frequency (every N IDs? every N seconds?)
- Recovery semantics (what if crash occurs between memory and RocksDB?)
**Resolution:** Define persistence model:
- Recommended: Flush every 1000 IDs + checkpoint on graceful shutdown
- On recovery: Load persisted value + add safety margin (+1000)

---

### :warning: Concerns (Should address or explain)

#### C1. No Input Validation Specification
**Location:** Planning 1.3.3
**Risk:** HIGH - DoS, index corruption
**Issue:** No documented limits for term serialization:
- Maximum term size?
- Null byte handling?
- Unicode normalization (NFC vs NFD)?
**Recommendation:** Add validation requirements:
- Max term size: 16KB
- Reject null bytes in URIs
- Normalize to NFC before encoding

#### C2. Sequence Counter Overflow Protection
**Location:** Planning 1.3.2
**Risk:** HIGH - ID collision at scale
**Issue:** 60-bit sequence space (~1.15 quadrillion IDs) is large but not infinite. No overflow detection mentioned.
**Recommendation:**
- Implement overflow guard in `next_sequence()` that returns error near 2^60
- Add telemetry to alert at 50% utilization

#### C3. Missing Type Specifications
**Location:** `/lib/triple_store/dictionary.ex`
**Risk:** MEDIUM - Dialyzer failures, maintainability
**Issue:** No `@spec` or `@type` definitions in current stub.
**Recommendation:** Add before implementation:
```elixir
@type term_id :: non_neg_integer()  # 64-bit
@type sequence :: non_neg_integer()  # 60-bit
@type term_type :: :uri | :bnode | :literal | :integer | :decimal | :datetime

@spec encode_id(non_neg_integer(), sequence()) :: term_id()
@spec decode_id(term_id()) :: {term_type(), sequence()}
```

#### C4. ID Space Collision Risk
**Location:** Planning 1.3.1 + 1.3.5
**Risk:** MEDIUM - Subtle bugs
**Issue:** No documented mechanism to prevent collision between dictionary-allocated IDs and inline-encoded values.
**Recommendation:** Use non-overlapping ranges:
- Dictionary terms (types 1-3): sequence counter allocates from these
- Inline numerics (types 4-6): value encoded directly, no sequence

#### C5. No Concurrent Access Tests Specified
**Location:** Planning 1.3.6
**Risk:** MEDIUM - Latent production defects
**Issue:** Test requirements don't include concurrent allocation scenarios.
**Recommendation:** Add to test plan:
- Spawn 10+ tasks allocating IDs concurrently, verify no duplicates
- Simulate crash during ID creation, verify recovery

---

### :bulb: Suggestions (Nice to have improvements)

#### S1. Extract Common NIF Patterns
**Location:** `/native/rocksdb_nif/src/lib.rs`
**Issue:** ~37% of NIF code is duplicated patterns (db guard extraction, CF resolution, binary copying).
**Suggestion:** Future refactoring could eliminate ~495 lines:
- Database guard helper function
- Column family resolver helper
- Binary encoding utilities

#### S2. Add Batch Lookup Functions
**Location:** Planning 1.3.3-1.3.4
**Issue:** Only `lookup_terms(db, ids)` mentioned for batch operations.
**Suggestion:** Consider adding:
- `get_or_create_ids(db, terms)` for bulk loading efficiency
- `lookup_term_stream(db, ids)` for large result sets

#### S3. Configure Dialyzer
**Location:** Project configuration
**Issue:** No `.dialyzer.exs` configuration found.
**Suggestion:** Add before Section 1.3 completion:
```elixir
# mix.exs
{:dialyxir, "~> 1.4", only: :dev, runtime: false}
```

#### S4. Document Precision Guarantees
**Location:** Planning 1.3.5
**Suggestion:** Explicitly document:
- Which `xsd:decimal` values are lossless?
- Rounding behavior for out-of-range values?
- Subsecond precision for `xsd:dateTime`?

---

### :white_check_mark: Good Practices Noticed

#### G1. Solid Architectural Foundation
The 64-bit ID encoding with 4-bit type tags is well-designed:
- O(1) type checking via bit extraction
- Natural sorting within type groups
- Extensible (room for additional types in 4-bit space)

#### G2. Consistent Error Handling Patterns
Existing NIF code consistently uses:
- `{:ok, value}` for success
- `:not_found` for missing data
- `{:error, reason}` for errors

Planning follows this pattern correctly.

#### G3. Strategic Inline Encoding
Inline numeric encoding is a strong optimization:
- Avoids dictionary lookup for FILTER evaluation
- Critical for query performance in Phase 2
- Backward compatible (falls back to dictionary for out-of-range values)

#### G4. Column Family Separation
Separating `str2id` and `id2str` into different column families enables:
- Independent scaling
- Different compression strategies
- Efficient bidirectional lookup

#### G5. Test Organization Structure
Existing test structure provides clear pattern to follow:
```
test/triple_store/backend/rocksdb/
├── lifecycle_test.exs
├── read_write_test.exs
├── write_batch_test.exs
├── iterator_test.exs
├── snapshot_test.exs
└── integration_test.exs
```

---

## Test Coverage Analysis

### Required Tests (from Planning 1.3.6)

| # | Test Requirement | Status |
|---|------------------|--------|
| 1 | Type tag encoding/decoding roundtrip | :x: Missing |
| 2 | Sequence counter atomic increments | :x: Missing |
| 3 | Sequence counter persists across restarts | :x: Missing |
| 4 | String-to-ID mapping for URIs | :x: Missing |
| 5 | String-to-ID mapping for blank nodes | :x: Missing |
| 6 | String-to-ID mapping for typed literals | :x: Missing |
| 7 | String-to-ID mapping for language-tagged literals | :x: Missing |
| 8 | ID-to-string reverse lookup | :x: Missing |
| 9 | Inline integer encoding/decoding | :x: Missing |
| 10 | Inline decimal encoding/decoding | :x: Missing |
| 11 | Inline datetime encoding/decoding | :x: Missing |
| 12 | get_or_create_id idempotency | :x: Missing |

**Coverage: 0/12 (0%)**

### Recommended Test Structure

```
test/triple_store/dictionary/
├── term_id_encoding_test.exs    (Task 1.3.1)
├── sequence_counter_test.exs    (Task 1.3.2)
├── string_to_id_test.exs        (Task 1.3.3)
├── id_to_string_test.exs        (Task 1.3.4)
├── inline_numeric_test.exs      (Task 1.3.5)
└── integration_test.exs         (Task 1.3.6)
```

### Additional Tests Recommended

- Edge cases: 2^60 boundary, negative integers, Unicode normalization
- Concurrent access: parallel ID allocation stress test
- Recovery: crash simulation and counter recovery
- Performance: lookup latency benchmarks

---

## Security Considerations

### High Priority

1. **Input Validation** - Validate term size limits, reject special characters
2. **Race Condition Protection** - Atomic `get_or_create_id` implementation
3. **Overflow Detection** - Guard against sequence counter wraparound

### Medium Priority

4. **Unicode Normalization** - Prevent encoding collisions via NFC normalization
5. **Error Information** - Don't leak internal state in error messages

### Low Priority (Design Awareness)

6. **ID Enumeration** - Sequential IDs leak cardinality information
7. **Precision Loss** - Document inline encoding limitations

---

## Elixir-Specific Recommendations

### Binary Pattern Matching
```elixir
# Recommended ID encoding pattern
def encode_id(type, sequence) when type in 0..15 and sequence >= 0 do
  <<type::4, sequence::60>>
end

def decode_id(<<type::4, sequence::60>>) do
  {type_to_atom(type), sequence}
end
```

### Sequence Counter
```elixir
# Use :atomics for lock-free increments
{:ok, counter_ref} = :atomics.new(1, signed: false)
:atomics.put(counter_ref, 1, initial_value)

def next_sequence(counter_ref) do
  :atomics.add_get(counter_ref, 1, 1)
end
```

### GenServer for Persistence
```elixir
# Recommended: Separate GenServer for counter management
defmodule TripleStore.Dictionary.SequenceCounter do
  use GenServer

  # Manages :atomics reference
  # Implements periodic flush to RocksDB
  # Handles recovery on startup
end
```

---

## Consistency with Codebase

| Aspect | Codebase Pattern | Section 1.3 Planning | Status |
|--------|------------------|---------------------|--------|
| Module naming | `TripleStore.X.Y` | `TripleStore.Dictionary` | :white_check_mark: Consistent |
| Error returns | `{:ok, v}` / `{:error, r}` | Same pattern | :white_check_mark: Consistent |
| Function naming | `encode_x`, `decode_x`, `lookup_x` | Follows pattern | :white_check_mark: Consistent |
| Documentation | Full `@doc` with examples | To be implemented | :warning: Needs attention |
| Type specs | `@spec` on all functions | Not in stub | :warning: Needs attention |

---

## Recommendations Summary

### Before Implementation

1. **Resolve B1-B3** - Define atomic create semantics, numeric encoding precision, persistence strategy
2. **Add type specifications** - Define `@type` and `@spec` for all planned functions
3. **Document encoding formats** - Bit-level specification for inline numerics

### During Implementation

4. **Follow existing patterns** - Match NIF module documentation and error handling style
5. **Implement overflow guards** - Prevent silent wraparound in sequence counter
6. **Add input validation** - Size limits, null byte rejection, Unicode normalization

### After Implementation

7. **Run Dialyzer** - Configure and verify type safety
8. **Complete test suite** - All 12 required tests + concurrent access tests
9. **Create summary document** - Following existing pattern in `notes/summaries/`

---

## Files Referenced

**Planning:**
- `/home/ducky/code/triple_store/notes/planning/phase-01-storage-foundation.md` (lines 143-224)

**Current Implementation:**
- `/home/ducky/code/triple_store/lib/triple_store/dictionary.ex` (stub)

**Pattern References:**
- `/home/ducky/code/triple_store/lib/triple_store/backend/rocksdb/nif.ex`
- `/home/ducky/code/triple_store/native/rocksdb_nif/src/lib.rs`
- `/home/ducky/code/triple_store/test/triple_store/backend/rocksdb/`

---

## Conclusion

Section 1.3 (Dictionary Encoding) has a solid architectural design that will integrate well with the completed RocksDB NIF layer. The main gaps are in **specification precision** (numeric encoding formats, persistence strategy) rather than architectural flaws.

**Recommended approach:**
1. Resolve the 3 blockers before starting implementation
2. Implement tasks 1.3.1-1.3.5 sequentially (each builds on previous)
3. Write tests alongside implementation (not after)
4. Create summary document following existing pattern

The 170 existing tests in the RocksDB layer provide a strong foundation, and the dictionary layer should maintain the same quality standard.
