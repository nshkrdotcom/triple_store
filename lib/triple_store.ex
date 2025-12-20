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

  ## Architecture

  The triple store uses:
  - RocksDB for persistent storage via Rustler NIFs
  - Dictionary encoding for compact term representation
  - SPO/POS/OSP indices for efficient pattern matching
  - Forward-chaining materialization for OWL 2 RL reasoning
  """
end
