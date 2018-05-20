defmodule ExWire do
  @moduledoc """
  Main application for ExWire. We will begin listening on a port
  when this application is started.
  """

  @type node_id :: binary()

  use Application

  def start(_type, args) do
    import Supervisor.Spec

    name = Keyword.get(args, :name, ExWire)

    sync_children =
      if ExWire.Config.sync() do
        # TODO: Replace with level db
        db = MerklePatriciaTree.Test.random_ets_db()

        [
          worker(ExWire.PeerSupervisor, [ExWire.Config.bootnodes()]),
          worker(ExWire.Sync, [db])
        ]
      else
        []
      end

    children =
      [
        worker(ExWire.NodeDiscoverySupervisor, [])
      ] ++ sync_children

    opts = [strategy: :one_for_one, name: name]
    Supervisor.start_link(children, opts)
  end
end
