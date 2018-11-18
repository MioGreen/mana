defmodule ExWire.Packet.GetSnapshotData do
  @moduledoc """
  Request a chunk (identified by the given hash) from a peer.

  ```
  `GetSnapshotData` [`0x13`, `chunk_hash`: B_32]
  ```
  """

  @behaviour ExWire.Packet

  @type t :: %__MODULE__{
          chunk_hash: EVM.hash()
        }

  defstruct [
    :chunk_hash
  ]

  @doc """
  Given a GetSnapshotData packet, serializes for transport over Eth Wire Protocol.

  ## Examples

      iex> %ExWire.Packet.GetSnapshotData{chunk_hash: <<1::256>>}
      ...> |> ExWire.Packet.GetSnapshotData.serialize()
      [<<1::256>>]
  """
  @spec serialize(t()) :: ExRLP.t()
  def serialize(%__MODULE__{chunk_hash: chunk_hash}) do
    [
      chunk_hash
    ]
  end

  @doc """
  Given an RLP-encoded GetSnapshotData packet from Eth Wire Protocol,
  decodes into a GetSnapshotData struct.

  ## Examples

      iex> ExWire.Packet.GetSnapshotData.deserialize([<<1::256>>])
      %ExWire.Packet.GetSnapshotData{chunk_hash: <<1::256>>}
  """
  @spec deserialize(ExRLP.t()) :: t()
  def deserialize(rlp) do
    [chunk_hash] = rlp

    %__MODULE__{chunk_hash: chunk_hash}
  end

  @doc """
  Handles a GetSnapshotData message. We should send our manifest
  to the peer. For now, we'll do nothing.

  ## Examples

      iex> %ExWire.Packet.GetSnapshotData{}
      ...> |> ExWire.Packet.GetSnapshotData.handle()
      :ok
  """
  @spec handle(ExWire.Packet.packet()) :: ExWire.Packet.handle_response()
  def handle(_packet = %__MODULE__{}) do
    :ok
  end
end
