defmodule TripleStore.PooledDbCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      use ExUnit.Case, async: true
      alias TripleStore.Backend.RocksDB.NIF
    end
  end

  setup do
    db_info = TripleStore.Test.DbPool.checkout()
    on_exit(fn -> TripleStore.Test.DbPool.checkin(db_info) end)
    {:ok, db: db_info.db, db_path: db_info.path}
  end
end
