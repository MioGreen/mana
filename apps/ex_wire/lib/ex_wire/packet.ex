defmodule ExWire.Packet do
  @moduledoc """
  Packets handle serializing and deserializing framed packet data from
  the DevP2P and Eth Wire Protocols. They also handle how to respond
  to incoming packets.
  """

  alias ExWire.Packet

  @type packet :: struct()
  @type block_identifier :: binary() | integer()
  @type block_hash :: {binary(), integer()}

  @callback serialize(packet) :: ExRLP.t()
  @callback deserialize(ExRLP.t()) :: packet
  # @callback summary(packet) :: String.t()

  @type handle_response ::
          :ok | :activate | :peer_disconnect | {:disconnect, atom()} | {:send, struct()}
  @callback handle(packet) :: handle_response

  # TODO: The packet numbers here are... wrong. It's not explained in the docs
  #       but here's the algorithm from other implementations:
  # Let index=0, offset=0x10
  # for (cap, index) in sorted(caps):
  #   let cap.offset = offset
  #   offset += cap.packet_count

  @packet_types %{
    0x00 => Packet.Hello,
    0x01 => Packet.Disconnect,
    0x02 => Packet.Ping,
    0x03 => Packet.Pong,
    ### Ethereum Sub-protocol
    0x10 => Packet.Status,
    # New model syncing (PV62)
    0x22 => Packet.NewBlockHashes,
    0x23 => Packet.Transactions,
    0x24 => Packet.GetBlockHeaders,
    0x25 => Packet.BlockHeaders,
    0x26 => Packet.GetBlockBodies,
    0x27 => Packet.BlockBodies,
    # 0x17 => Packet.NewBlock,
    ### Fast synchronization (PV63)
    # 0x1d => Packet.GetNodeData,
    # 0x1e => Packet.NodeData,
    # 0x1f => Packet.GetReceipts,
    # 0x20 => Packet.Receipts,
    ### Warp Sync (par)
    # TODO: Fix the hack out of this
    0x21 => Packet.WarpStatus,
    0x32 => Packet.GetSnapshotManifest,
    0x33 => Packet.SnapshotManifest,
    0x34 => Packet.GetSnapshotData,
    0x35 => Packet.SnapshotData
  }

  @packet_types_inverted for({k, v} <- @packet_types, do: {v, k}) |> Enum.into(%{})

  @doc """
  Returns the module which contains functions to
  `serialize/1`, `deserialize/1` and `handle/1` the given `packet_type`.

  ## Examples

      iex> ExWire.Packet.get_packet_mod(0x00)
      {:ok, ExWire.Packet.Hello}

      iex> ExWire.Packet.get_packet_mod(0x10)
      {:ok, ExWire.Packet.Status}

      iex> ExWire.Packet.get_packet_mod(0xFF)
      :unknown_packet_type
  """
  @spec get_packet_mod(integer()) :: {:ok, module()} | :unknown_packet_type
  def get_packet_mod(packet_type) do
    case @packet_types[packet_type] do
      nil -> :unknown_packet_type
      packet_type -> {:ok, packet_type}
    end
  end

  @doc """
  Returns the eth id of the given packet based on the struct.

  ## Examples

      iex> ExWire.Packet.get_packet_type(%ExWire.Packet.Hello{})
      {:ok, 0x00}

      iex> ExWire.Packet.get_packet_type(%ExWire.Packet.Status{})
      {:ok, 0x10}

      iex> ExWire.Packet.get_packet_type(%ExWire.Struct.Neighbour{})
      :unknown_packet
  """
  @spec get_packet_type(struct()) :: {:ok, integer()} | :unknown_packet
  def get_packet_type(_packet = %{__struct__: packet_struct}) do
    case @packet_types_inverted[packet_struct] do
      nil -> :unknown_packet
      packet_type -> {:ok, packet_type}
    end
  end
end
