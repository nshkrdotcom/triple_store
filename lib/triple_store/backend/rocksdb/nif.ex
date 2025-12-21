defmodule TripleStore.Backend.RocksDB.NIF do
  @moduledoc """
  NIF bindings for RocksDB operations.

  This module contains the low-level NIF function declarations that interface
  with the Rust implementation in `native/rocksdb_nif`.

  ## Usage

  These functions should not be called directly. Use the higher-level
  `TripleStore.Backend.RocksDB` module instead.

  ## Configuration

  To skip NIF compilation during development (when Rust is not installed),
  set the environment variable `RUSTLER_SKIP_COMPILATION=1`.

  ## Column Families

  The database uses the following column families:
  - `:id2str` - Maps 64-bit IDs to string values
  - `:str2id` - Maps string values to 64-bit IDs
  - `:spo` - Subject-Predicate-Object index
  - `:pos` - Predicate-Object-Subject index
  - `:osp` - Object-Subject-Predicate index
  - `:derived` - Stores inferred triples from reasoning
  """

  @skip_compilation System.get_env("RUSTLER_SKIP_COMPILATION") == "1"

  use Rustler,
    otp_app: :triple_store,
    crate: "rocksdb_nif",
    skip_compilation?: @skip_compilation

  @type db_ref :: reference()
  @type column_family :: :id2str | :str2id | :spo | :pos | :osp | :derived

  @doc """
  Verifies that the NIF is loaded correctly.

  Returns `"rocksdb_nif"` if the NIF is operational.

  ## Examples

      iex> TripleStore.Backend.RocksDB.NIF.nif_loaded()
      "rocksdb_nif"

  """
  @spec nif_loaded :: String.t()
  def nif_loaded, do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Opens a RocksDB database at the given path.

  Creates the database and all required column families if they don't exist.
  Uses dirty CPU scheduler to prevent blocking BEAM schedulers.

  ## Arguments
  - `path` - Path to the database directory

  ## Returns
  - `{:ok, db_ref}` on success
  - `{:error, {:open_failed, reason}}` on failure

  ## Examples

      iex> {:ok, db} = TripleStore.Backend.RocksDB.NIF.open("/tmp/test_db")
      iex> is_reference(db)
      true

  """
  @spec open(String.t()) :: {:ok, db_ref()} | {:error, {:open_failed, String.t()}}
  def open(_path), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Closes the database and releases all resources.

  After calling close, the database handle is no longer valid.
  Uses dirty CPU scheduler to prevent blocking BEAM schedulers.

  ## Arguments
  - `db_ref` - The database reference to close

  ## Returns
  - `:ok` on success
  - `{:error, :already_closed}` if already closed

  ## Examples

      iex> {:ok, db} = TripleStore.Backend.RocksDB.NIF.open("/tmp/test_db")
      iex> TripleStore.Backend.RocksDB.NIF.close(db)
      :ok

  """
  @spec close(db_ref()) :: :ok | {:error, :already_closed}
  def close(_db_ref), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Returns the path of the database.

  ## Arguments
  - `db_ref` - The database reference

  ## Returns
  - `{:ok, path}` with the database path
  """
  @spec get_path(db_ref()) :: {:ok, String.t()}
  def get_path(_db_ref), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Lists all column families in the database.

  ## Returns
  - List of column family atoms: `[:id2str, :str2id, :spo, :pos, :osp, :derived]`
  """
  @spec list_column_families :: [column_family()]
  def list_column_families, do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Checks if the database is open.

  ## Arguments
  - `db_ref` - The database reference

  ## Returns
  - `true` if open, `false` if closed
  """
  @spec is_open(db_ref()) :: boolean()
  # credo:disable-for-next-line Credo.Check.Readability.PredicateFunctionNames
  def is_open(_db_ref), do: :erlang.nif_error(:nif_not_loaded)

  # ============================================================================
  # Key-Value Operations
  # ============================================================================

  @doc """
  Gets a value from a column family.

  Uses dirty CPU scheduler to prevent blocking BEAM schedulers.

  ## Arguments
  - `db_ref` - The database reference
  - `cf` - The column family atom
  - `key` - The key as a binary

  ## Returns
  - `{:ok, value}` if found
  - `:not_found` if key doesn't exist
  - `{:error, :already_closed}` if database is closed
  - `{:error, {:invalid_cf, cf}}` if column family is invalid
  - `{:error, {:get_failed, reason}}` on other errors

  ## Examples

      iex> {:ok, db} = NIF.open("/tmp/test_db")
      iex> NIF.put(db, :id2str, "key1", "value1")
      :ok
      iex> NIF.get(db, :id2str, "key1")
      {:ok, "value1"}
      iex> NIF.get(db, :id2str, "nonexistent")
      :not_found

  """
  @spec get(db_ref(), column_family(), binary()) ::
          {:ok, binary()} | :not_found | {:error, term()}
  def get(_db_ref, _cf, _key), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Puts a key-value pair into a column family.

  Uses dirty CPU scheduler to prevent blocking BEAM schedulers.

  ## Arguments
  - `db_ref` - The database reference
  - `cf` - The column family atom
  - `key` - The key as a binary
  - `value` - The value as a binary

  ## Returns
  - `:ok` on success
  - `{:error, :already_closed}` if database is closed
  - `{:error, {:invalid_cf, cf}}` if column family is invalid
  - `{:error, {:put_failed, reason}}` on other errors

  ## Examples

      iex> {:ok, db} = NIF.open("/tmp/test_db")
      iex> NIF.put(db, :id2str, "key1", "value1")
      :ok

  """
  @spec put(db_ref(), column_family(), binary(), binary()) :: :ok | {:error, term()}
  def put(_db_ref, _cf, _key, _value), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Deletes a key from a column family.

  Uses dirty CPU scheduler to prevent blocking BEAM schedulers.

  ## Arguments
  - `db_ref` - The database reference
  - `cf` - The column family atom
  - `key` - The key to delete

  ## Returns
  - `:ok` on success (even if key didn't exist)
  - `{:error, :already_closed}` if database is closed
  - `{:error, {:invalid_cf, cf}}` if column family is invalid
  - `{:error, {:delete_failed, reason}}` on other errors

  ## Examples

      iex> {:ok, db} = NIF.open("/tmp/test_db")
      iex> NIF.put(db, :id2str, "key1", "value1")
      :ok
      iex> NIF.delete(db, :id2str, "key1")
      :ok
      iex> NIF.get(db, :id2str, "key1")
      :not_found

  """
  @spec delete(db_ref(), column_family(), binary()) :: :ok | {:error, term()}
  def delete(_db_ref, _cf, _key), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Checks if a key exists in a column family.

  Uses dirty CPU scheduler to prevent blocking BEAM schedulers.
  More efficient than `get/3` when you only need to check existence.

  ## Arguments
  - `db_ref` - The database reference
  - `cf` - The column family atom
  - `key` - The key to check

  ## Returns
  - `{:ok, true}` if key exists
  - `{:ok, false}` if key doesn't exist
  - `{:error, :already_closed}` if database is closed
  - `{:error, {:invalid_cf, cf}}` if column family is invalid
  - `{:error, {:get_failed, reason}}` on other errors

  ## Examples

      iex> {:ok, db} = NIF.open("/tmp/test_db")
      iex> NIF.put(db, :id2str, "key1", "value1")
      :ok
      iex> NIF.exists(db, :id2str, "key1")
      {:ok, true}
      iex> NIF.exists(db, :id2str, "nonexistent")
      {:ok, false}

  """
  @spec exists(db_ref(), column_family(), binary()) :: {:ok, boolean()} | {:error, term()}
  def exists(_db_ref, _cf, _key), do: :erlang.nif_error(:nif_not_loaded)

  # ============================================================================
  # Batch Operations
  # ============================================================================

  @type put_operation :: {column_family(), binary(), binary()}
  @type delete_operation :: {column_family(), binary()}
  @type mixed_put :: {:put, column_family(), binary(), binary()}
  @type mixed_delete :: {:delete, column_family(), binary()}

  @doc """
  Atomically writes multiple key-value pairs to column families.

  Uses RocksDB WriteBatch for atomic commit - either all operations succeed
  or none do. Uses dirty CPU scheduler to prevent blocking BEAM schedulers.

  ## Arguments
  - `db_ref` - The database reference
  - `operations` - List of `{cf, key, value}` tuples

  ## Returns
  - `:ok` on success
  - `{:error, :already_closed}` if database is closed
  - `{:error, {:invalid_cf, cf}}` if column family is invalid
  - `{:error, {:batch_failed, reason}}` on other errors

  ## Examples

      iex> {:ok, db} = NIF.open("/tmp/test_db")
      iex> operations = [
      ...>   {:id2str, "key1", "value1"},
      ...>   {:id2str, "key2", "value2"},
      ...>   {:str2id, "value1", "key1"}
      ...> ]
      iex> NIF.write_batch(db, operations)
      :ok

  """
  @spec write_batch(db_ref(), [put_operation()]) :: :ok | {:error, term()}
  def write_batch(_db_ref, _operations), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Atomically deletes multiple keys from column families.

  Uses RocksDB WriteBatch for atomic commit - either all operations succeed
  or none do. Uses dirty CPU scheduler to prevent blocking BEAM schedulers.

  ## Arguments
  - `db_ref` - The database reference
  - `operations` - List of `{cf, key}` tuples

  ## Returns
  - `:ok` on success
  - `{:error, :already_closed}` if database is closed
  - `{:error, {:invalid_cf, cf}}` if column family is invalid
  - `{:error, {:batch_failed, reason}}` on other errors

  ## Examples

      iex> {:ok, db} = NIF.open("/tmp/test_db")
      iex> NIF.write_batch(db, [{:id2str, "key1", "value1"}, {:id2str, "key2", "value2"}])
      :ok
      iex> NIF.delete_batch(db, [{:id2str, "key1"}, {:id2str, "key2"}])
      :ok

  """
  @spec delete_batch(db_ref(), [delete_operation()]) :: :ok | {:error, term()}
  def delete_batch(_db_ref, _operations), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Atomically performs mixed put and delete operations.

  Uses RocksDB WriteBatch for atomic commit - either all operations succeed
  or none do. This is essential for maintaining consistency when updating
  multiple indices (SPO, POS, OSP) for a single triple.

  Uses dirty CPU scheduler to prevent blocking BEAM schedulers.

  ## Arguments
  - `db_ref` - The database reference
  - `operations` - List of operations:
    - `{:put, cf, key, value}` for puts
    - `{:delete, cf, key}` for deletes

  ## Returns
  - `:ok` on success
  - `{:error, :already_closed}` if database is closed
  - `{:error, {:invalid_cf, cf}}` if column family is invalid
  - `{:error, {:invalid_operation, op}}` if operation type is invalid
  - `{:error, {:batch_failed, reason}}` on other errors

  ## Examples

      iex> {:ok, db} = NIF.open("/tmp/test_db")
      iex> operations = [
      ...>   {:put, :spo, "s1p1o1", ""},
      ...>   {:put, :pos, "p1o1s1", ""},
      ...>   {:delete, :spo, "old_key"},
      ...>   {:delete, :pos, "old_key2"}
      ...> ]
      iex> NIF.mixed_batch(db, operations)
      :ok

  """
  @spec mixed_batch(db_ref(), [mixed_put() | mixed_delete()]) :: :ok | {:error, term()}
  def mixed_batch(_db_ref, _operations), do: :erlang.nif_error(:nif_not_loaded)
end
