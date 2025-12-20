defmodule TripleStore.Backend do
  @moduledoc """
  Storage backend abstraction for the triple store.

  This module defines the behaviour for storage backends and provides
  the interface for low-level storage operations. The primary implementation
  is `TripleStore.Backend.RocksDB` which uses RocksDB via Rustler NIFs.

  ## Backend Responsibilities

  - Database lifecycle (open, close)
  - Key-value operations (get, put, delete)
  - Batch operations for atomic writes
  - Iterator operations for range queries
  - Snapshot support for consistent reads
  """
end
