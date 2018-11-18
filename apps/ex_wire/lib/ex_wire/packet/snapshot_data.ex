defmodule ExWire.Packet.SnapshotData do
  @moduledoc """
  Respond to a GetSnapshotData message with either an empty RLP list or a
  1-item RLP list containing the raw chunk data requested.

  ```
  `SnapshotData` [`0x14`, `chunk_data` or nothing]
  ```
  """
  alias ExWire.Packet.SnapshotData.{BlockChunk, StateChunk}
  alias ExthCrypto.Hash.Keccak

  @behaviour ExWire.Packet

  @type t :: %__MODULE__{
          hash: EVM.hash(),
          chunk: BlockChunk.t() | StateChunk.t() | nil
        }

  defstruct [:hash, :chunk]

  @doc """
  Given a SnapshotData packet, serializes for transport over Eth Wire Protocol.

  ## Examples

      iex> %ExWire.Packet.SnapshotData{
      ...>   chunk: %ExWire.Packet.SnapshotData.BlockChunk{
      ...>     number: 5,
      ...>     hash: <<6::256>>,
      ...>     total_difficulty: 7,
      ...>     block_data_list: []
      ...>    }
      ...> }
      ...> |> ExWire.Packet.SnapshotData.serialize()
      [<<36, 12, 227, 5, 160, 0, 118, 1, 0, 4, 6, 7>>]

      iex> %ExWire.Packet.SnapshotData{
      ...>   chunk: %ExWire.Packet.SnapshotData.StateChunk{
      ...>     account_entries: []
      ...>   }
      ...> }
      ...> |> ExWire.Packet.SnapshotData.serialize()
      [<<1, 0, 192>>]
  """
  @spec serialize(t) :: ExRLP.t()
  def serialize(%__MODULE__{chunk: chunk = %{__struct__: mod}}) do
    {:ok, res} =
      mod.serialize(chunk)
      |> ExRLP.encode()
      |> :snappyer.compress()

    [res]
  end

  @doc """
  Given an RLP-encoded SnapshotData packet from Eth Wire Protocol,
  decodes into a SnapshotData struct.

  ## Examples

      iex> [<<36, 12, 227, 5, 160, 0, 118, 1, 0, 4, 6, 7>>]
      ...> |> ExWire.Packet.SnapshotData.deserialize(true)
      %ExWire.Packet.SnapshotData{
        chunk: %ExWire.Packet.SnapshotData.BlockChunk{
          number: <<5>>,
          hash: <<6::256>>,
          total_difficulty: <<7>>,
          block_data_list: []
         }
      }

      iex> [<<1, 0, 192>>]
      ...> |> ExWire.Packet.SnapshotData.deserialize(false)
      %ExWire.Packet.SnapshotData{
        chunk: %ExWire.Packet.SnapshotData.StateChunk{
          account_entries: []
        }
      }
  """
  @spec deserialize(ExRLP.t(), boolean()) :: t()
  def deserialize(rlp, is_block_chunk \\ true) do
    [chunk_data] = rlp

    hash = Keccak.kec(chunk_data)

    {:ok, chunk_rlp_encoded} = :snappyer.decompress(chunk_data)

    chunk_rlp = ExRLP.decode(chunk_rlp_encoded)

    chunk =
      if is_block_chunk do
        BlockChunk.deserialize(chunk_rlp)
      else
        StateChunk.deserialize(chunk_rlp)
      end

    %__MODULE__{chunk: chunk, hash: hash}
  end

  @doc """
  Handles a SnapshotData message. We should send our manifest
  to the peer. For now, we'll do nothing.

  ## Examples

      iex> %ExWire.Packet.SnapshotData{}
      ...> |> ExWire.Packet.SnapshotData.handle()
      :ok
  """
  @spec handle(ExWire.Packet.packet()) :: ExWire.Packet.handle_response()
  def handle(_packet = %__MODULE__{}) do
    :ok
  end
end
