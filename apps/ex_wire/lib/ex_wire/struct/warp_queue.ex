defmodule ExWire.Struct.WarpQueue do
  @moduledoc """
  `WarpQueue` maintains the current state of an active warp, this mean we will 
  track the block_chunk hashes and state_chunk hashes given to us, so we can
  request each from peers.

  TODO: This will likely need to be updated to handle warping from more than
        one direct peer.
  """
  require Logger

  alias Block.Header
  alias Blockchain.{Block, Blocktree}
  alias ExWire.Packet.SnapshotData.BlockChunk
  alias ExWire.Packet.SnapshotManifest
  alias MerklePatriciaTree.{Trie, TrieStorage}

  @type t :: %{
          manifests: [SnapshotManifest.manifest()],
          known_block_hashes: MapSet.t(EVM.hash()),
          known_stash_hashes: MapSet.t(EVM.hash()),
          block_chunk_requests: MapSet.t(EVM.hash()),
          retrieved_block_chunks: MapSet.t(EVM.hash()),
          unprocessed_blocks: list({Block.t(), BlockData.t()}),
          processed_blocks: MapSet.t()
        }
  defstruct [
    :manifests,
    :known_block_hashes,
    :known_state_hashes,
    :block_chunk_requests,
    :retrieved_block_chunks,
    :unprocessed_blocks,
    :processed_blocks
  ]

  @doc """
  Creates a new `WarpQueue`.
  """
  def new() do
    %__MODULE__{
      manifests: [],
      known_block_hashes: MapSet.new(),
      known_state_hashes: MapSet.new(),
      block_chunk_requests: MapSet.new(),
      retrieved_block_chunks: MapSet.new(),
      unprocessed_blocks: [],
      processed_blocks: MapSet.new()
    }
  end

  @spec new_manifest(t(), SnapshotManifest.manifest()) :: t()
  def new_manifest(warp_queue, manifest) do
    updated_known_block_hashes =
      MapSet.union(
        warp_queue.known_block_hashes,
        MapSet.new(manifest.block_hashes)
      )

    updated_known_state_hashes =
      MapSet.union(
        warp_queue.known_state_hashes,
        MapSet.new(manifest.state_hashes)
      )

    %{
      warp_queue
      | manifests: [manifest | warp_queue.manifests],
        known_block_hashes: updated_known_block_hashes,
        known_state_hashes: updated_known_state_hashes
    }
  end

  @doc """
  When we receive a new block chunk, we want to remove it from requests
  and add it to our processing queue.
  """
  @spec new_block_chunk(WarpQueue.t(), EVM.hash(), BlockChunk.t()) :: WarpQueue.t()
  def new_block_chunk(warp_queue, block_chunk_hash, block_chunk) do
    updated_block_chunk_requests =
      MapSet.delete(warp_queue.block_chunk_requests, block_chunk_hash)

    updated_retrieved_block_chunks =
      MapSet.put(warp_queue.retrieved_block_chunks, block_chunk_hash)

    {_, _, updated_unprocessed_blocks} =
      Enum.reduce(
        block_chunk.block_data_list,
        {block_chunk.number, block_chunk.hash, warp_queue.unprocessed_blocks},
        fn block_data, {number, parent_hash, curr_unprocessed_blocks} ->
          block = get_block(block_data, parent_hash, number + 1)

          {
            number + 1,
            block.block_hash,
            [{block, block_data} | curr_unprocessed_blocks]
          }
        end
      )

    %{
      warp_queue
      | block_chunk_requests: updated_block_chunk_requests,
        retrieved_block_chunks: updated_retrieved_block_chunks,
        unprocessed_blocks: updated_unprocessed_blocks
    }
  end

  # TODO: We need to handle requesting state hashes, as well.
  @spec get_block_hashes_to_request(t(), integer()) :: {t(), list(EVM.hash())}
  def get_block_hashes_to_request(warp_queue, request_limit) do
    # blocks_hashes_to_request
    total_block_hashes_needed =
      warp_queue.known_block_hashes
      |> MapSet.difference(warp_queue.block_chunk_requests)
      |> MapSet.difference(warp_queue.retrieved_block_chunks)

    blocks_to_request =
      min(
        request_limit - Enum.count(warp_queue.block_chunk_requests),
        Enum.count(total_block_hashes_needed)
      )

    if blocks_to_request > 0 do
      :ok =
        Logger.debug(fn ->
          "Retreiving #{blocks_to_request} of #{Enum.count(total_block_hashes_needed)} block hash(es) needed."
        end)

      blocks_hashes_to_request = Enum.take(total_block_hashes_needed, blocks_to_request)

      new_block_chunk_requests =
        MapSet.union(
          warp_queue.block_chunk_requests,
          MapSet.new(blocks_hashes_to_request)
        )

      {
        %{warp_queue | block_chunk_requests: new_block_chunk_requests},
        blocks_hashes_to_request
      }
    else
      {warp_queue, []}
    end
  end

  @spec process_completed_blocks(WarpQueue.t(), Blocktree.t(), Trie.t()) ::
          {WarpQueue.t(), Blocktree.t(), Trie.t()}
  def process_completed_blocks(
        warp_queue = %__MODULE__{unprocessed_blocks: blocks, processed_blocks: processed_blocks},
        block_tree,
        trie
      ) do
    :ok = Logger.debug("Processing #{Enum.count(blocks)} block(s)")

    {next_block_tree, next_trie, next_processed_blocks} =
      Enum.reduce(blocks, {block_tree, trie, processed_blocks}, fn {block, block_data},
                                                                   {curr_block_tree, curr_trie,
                                                                    curr_processed_blocks} ->
        next_trie =
          process_block(
            block,
            block_data,
            curr_trie
          )

        next_block_tree = Blocktree.update_best_block(curr_block_tree, block)

        {next_block_tree, next_trie, MapSet.put(curr_processed_blocks, block.header.number)}
      end)

    # Show some stats for debugging
    list =
      next_processed_blocks
      |> MapSet.to_list()
      |> Enum.sort()

    min = List.first(list)

    {max, missing} =
      Enum.reduce(Enum.drop(list, 1), {min, 0}, fn el, {last, count} ->
        {el, count + el - last - 1}
      end)

    :ok =
      Logger.debug(fn ->
        "Processed blocks #{min}..#{max} with #{missing} missing block(s)"
      end)

    {
      %{warp_queue | unprocessed_blocks: [], processed_blocks: next_processed_blocks},
      next_block_tree,
      next_trie
    }
  end

  @spec get_block(BlockData.t(), EVM.hash(), integer()) :: Block.t()
  defp get_block(block_data, parent_hash, number) do
    transactions_hash = get_transactions_or_receipts_root(block_data.header.transactions_rlp)
    ommers_hash = get_ommers_hash(block_data.header.ommers_rlp)
    receipts_root = get_transactions_or_receipts_root(block_data.receipts_rlp)

    header = %Header{
      parent_hash: parent_hash,
      ommers_hash: ommers_hash,
      beneficiary: block_data.header.author,
      state_root: block_data.header.state_root,
      transactions_root: transactions_hash,
      receipts_root: receipts_root,
      logs_bloom: block_data.header.logs_bloom,
      difficulty: block_data.header.difficulty,
      number: number,
      gas_limit: block_data.header.gas_limit,
      gas_used: block_data.header.gas_used,
      timestamp: block_data.header.timestamp,
      extra_data: block_data.header.extra_data,
      mix_hash: block_data.header.mix_hash,
      nonce: block_data.header.nonce
    }

    %Block{
      block_hash: Header.hash(header),
      header: header,
      transactions: block_data.header.transactions,
      receipts: block_data.receipts,
      ommers: block_data.header.ommers
    }
  end

  # Note: we haven't connected state hashes, so we're not there yet
  @spec process_block(Block.t(), BlockData.t(), Trie.t()) :: Trie.t()
  defp process_block(block, block_data, trie) do
    # First, we need to validate some aspect of the block, that's currently
    # ommited.

    # Store the block to our db, trying not to repeat encodings of our
    # transactions and ommers.
    block_encoded_rlp =
      [
        Header.serialize(block.header),
        block_data.header.transactions_rlp,
        block_data.header.ommers_rlp
      ]
      |> ExRLP.encode()

    next_trie = TrieStorage.put_raw_key!(trie, block.block_hash, block_encoded_rlp)

    # TODO: Store each transaction to our db
    # {subtrie, updated_trie} =
    #   TrieStorage.update_subtrie_key(
    #     trie,
    #     block.header.transactions_root,
    #     ExRLP.encode(i),
    #     encoded_transaction
    #   )

    # TODO: Store each receipt
    # {subtrie, updated_trie} =
    #   TrieStorage.update_subtrie_key(
    #     trie,
    #     block.header.receipts_root,
    #     ExRLP.encode(i),
    #     encoded_receipt
    #   )

    next_trie
  end

  # Tries to get the transaction or receipts root by encoding the transaction trie
  @spec get_transactions_or_receipts_root([ExRLP.t()]) :: MerklePatriciaTree.Trie.root_hash()
  def get_transactions_or_receipts_root(transactions_or_receipts_rlp) do
    # this is a throw-away
    db = MerklePatriciaTree.Test.random_ets_db()

    trie =
      Enum.reduce(
        transactions_or_receipts_rlp |> Enum.with_index(),
        Trie.new(db),
        fn {trx_or_receipt, i}, trie ->
          Trie.update_key(trie, ExRLP.encode(i), ExRLP.encode(trx_or_receipt))
        end
      )

    trie.root_hash
  end

  @spec get_ommers_hash(list(binary())) :: ExthCrypto.Hash.hash()
  def get_ommers_hash(ommers_rlp) do
    ommers_rlp
    |> ExRLP.encode()
    |> ExthCrypto.Hash.Keccak.kec()
  end
end
