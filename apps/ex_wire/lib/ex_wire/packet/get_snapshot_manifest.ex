defmodule ExWire.Packet.GetSnapshotManifest do
  @moduledoc """
  Request a snapshot manifest in RLP form from a peer.

  ```
  `GetSnapshotManifest` [`0x11`]
  ```
  """

  @behaviour ExWire.Packet

  @type t :: %__MODULE__{}

  defstruct []

  @doc """
  Given a GetSnapshotManifest packet, serializes for transport over Eth Wire Protocol.

  ## Examples

      iex> %ExWire.Packet.GetSnapshotManifest{}
      ...> |> ExWire.Packet.GetSnapshotManifest.serialize()
      []
  """
  @spec serialize(t) :: ExRLP.t()
  def serialize(_packet = %__MODULE__{}) do
    []
  end

  @doc """
  Given an RLP-encoded GetSnapshotManifest packet from Eth Wire Protocol,
  decodes into a GetSnapshotManifest struct.

  ## Examples

      iex> ExWire.Packet.GetSnapshotManifest.deserialize([])
      %ExWire.Packet.GetSnapshotManifest{}
  """
  @spec deserialize(ExRLP.t()) :: t
  def deserialize(rlp) do
    [] = rlp

    %__MODULE__{}
  end

  @doc """
  Handles a GetSnapshotManifest message. We should send our manifest
  to the peer. For now, we'll do nothing.

  ## Examples

      iex> %ExWire.Packet.GetSnapshotManifest{}
      ...> |> ExWire.Packet.GetSnapshotManifest.handle()
      :ok
  """
  @spec handle(ExWire.Packet.packet()) :: ExWire.Packet.handle_response()
  def handle(_packet = %__MODULE__{}) do
    :ok
  end
end
