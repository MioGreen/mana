defmodule ExWire.Handler.FindNeighbours do
  @moduledoc """
  Module that handles a response to a FindNeighbours message, which generates a
  Neighbours response with the closest nodes to provided node id.
  """

  alias ExWire.{Handler, Kademlia}
  alias ExWire.Handler.Params
  alias ExWire.Kademlia.Node
  alias ExWire.Message.{FindNeighbours, Neighbours}
  alias ExWire.Struct.Neighbour

  @doc """
  Handler for a `FindNeighbors` message.

  ## Examples

      iex> {:ok, kademlia_process} = ExWire.FakeKademliaServer.start_link(
      ...>   [
      ...>     %ExWire.Kademlia.Node{
      ...>       public_key: <<1::256>>,
      ...>       key: <<1::160>>,
      ...>       endpoint: %ExWire.Struct.Endpoint{
      ...>         ip: [52, 169, 14, 227],
      ...>         tcp_port: nil,
      ...>         udp_port: 30303
      ...>       }
      ...>     }
      ...>   ]
      ...> )
      iex> ExWire.Handler.FindNeighbours.handle(%ExWire.Handler.Params{
      ...>   remote_host: %ExWire.Struct.Endpoint{ip: [1,2,3,4], udp_port: 55},
      ...>   signature: 2,
      ...>   recovery_id: 3,
      ...>   hash: <<5>>,
      ...>   data: [<<1>>, 2] |> ExRLP.encode,
      ...>   timestamp: 7,
      ...> }, kademlia_process_name: kademlia_process)
      %ExWire.Message.Neighbours{
        nodes: [
          %ExWire.Struct.Neighbour{
            endpoint: %ExWire.Struct.Endpoint{
              ip: [52, 169, 14, 227],
              tcp_port: nil,
              udp_port: 30303
            },
            node: <<1::256>>
          }
        ],
        timestamp: 7,
      }
  """
  @spec handle(Params.t(), Keyword.t()) :: Handler.handler_response()
  def handle(params, options \\ []) do
    neighbours = fetch_neighbours(params, options)

    %Neighbours{
      nodes: neighbours,
      timestamp: params.timestamp
    }
  end

  @doc """
  Gets the list of neighbors from the Kademlina running gen server.
  """
  @spec fetch_neighbours(Params.t(), Keyword.t()) :: [Neighbour.t()]
  def fetch_neighbours(params, options) do
    params.data
    |> FindNeighbours.decode()
    |> Kademlia.neighbours(params.remote_host, process_name: options[:kademlia_process_name])
    |> nodes_to_neighbours
  end

  @spec nodes_to_neighbours([Node.t()]) :: [Neighbour.t()]
  defp nodes_to_neighbours(nodes) do
    nodes
    |> Enum.map(fn node ->
      %Neighbour{endpoint: node.endpoint, node: node.public_key}
    end)
  end
end
