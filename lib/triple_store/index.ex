defmodule TripleStore.Index do
  @moduledoc """
  Triple index layer providing O(log n) access for all triple patterns.

  Maintains three indices over dictionary-encoded triples:
  - **SPO** (Subject-Predicate-Object): Primary index, used for subject-based lookups
  - **POS** (Predicate-Object-Subject): Used for predicate-based lookups
  - **OSP** (Object-Subject-Predicate): Used for object-based lookups

  ## Key Encoding

  Each index uses 24-byte keys (3 x 64-bit IDs) in big-endian format
  for correct lexicographic ordering:

      spo_key = <<subject::64-big, predicate::64-big, object::64-big>>
      pos_key = <<predicate::64-big, object::64-big, subject::64-big>>
      osp_key = <<object::64-big, subject::64-big, predicate::64-big>>

  ## Pattern Matching

  Given a triple pattern, the optimal index is selected based on which
  components are bound:

  | Pattern | Index | Operation |
  |---------|-------|-----------|
  | SPO, SP?, S?? | SPO | Prefix scan |
  | ?PO, ?P? | POS | Prefix scan |
  | ??O, S?O | OSP | Prefix scan |
  """
end
