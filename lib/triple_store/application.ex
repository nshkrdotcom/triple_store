defmodule TripleStore.Application do
  @moduledoc """
  OTP Application for the TripleStore.

  Manages the supervision tree for:
  - Database connections and lifecycle
  - Statistics caching
  - Query plan caching
  - Transaction coordination
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Children will be added as features are implemented:
      # - TripleStore.Statistics (Phase 1)
      # - TripleStore.Query.PlanCache (Phase 3)
      # - TripleStore.Transaction (Phase 3)
    ]

    opts = [strategy: :one_for_one, name: TripleStore.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
