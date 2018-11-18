defmodule ExWire.Sync do
  @moduledoc """
  This is the heart of our syncing logic. Once we've connected to a number
  of peers via `ExWire.PeerSupervisor`, we begin to ask for new blocks from
  those peers. As we receive blocks, we add them to our
  `ExWire.Struct.BlockQueue`.

  If the blocks are confirmed by enough peers, then we verify the block and
  add it to our block tree.

  Note: we do not currently store the block tree, and thus we need to build
        it from genesis each time.
  """
  use GenServer

  require Logger

  alias Block.Header
  alias Blockchain.Block
  alias ExWire.Config

  alias ExWire.Packet.{
    BlockBodies,
    BlockHeaders,
    GetBlockBodies,
    GetBlockHeaders,
    GetSnapshotData,
    GetSnapshotManifest,
    SnapshotData,
    SnapshotManifest
  }

  alias ExWire.Packet.SnapshotData.{BlockChunk, StateChunk}
  alias ExWire.PeerSupervisor
  alias ExWire.Struct.{BlockQueue, Peer, WarpQueue}
  alias Blockchain.{Blocktree, Chain}
  alias Blockchain.Blocktree.State
  alias MerklePatriciaTree.{CachingTrie, DB.RocksDB, Trie, TrieStorage}

  @save_block_interval 100
  @blocks_per_request 100
  @startup_delay 10_000
  @retry_delay 5_000
  @request_limit 5

  @type state :: %{
          chain: Chain.t(),
          block_queue: BlockQueue.t(),
          warp_queue: WarpQueue.t(),
          block_tree: Blocktree.t(),
          trie: Trie.t(),
          last_requested_block: integer() | nil,
          warp: boolean()
        }

  @doc """
  Starts a sync process for a given chain.
  """
  @spec start_link(Chain.t(), boolean()) :: GenServer.on_start()
  def start_link(chain, warp \\ true) do
    GenServer.start_link(__MODULE__, {chain, warp}, name: __MODULE__)
  end

  @doc """
  Once we start a sync server, we'll wait for active peers and
  then begin asking for blocks.

  TODO: Let's say we haven't connected to any peers before we call
        `request_next_block`, then the client effectively stops syncing.
        We should handle this case more gracefully.
  """
  @impl true
  def init({chain, warp}) do
    {block_tree, trie} = load_sync_state(chain)
    block_queue = %BlockQueue{}
    warp_queue = WarpQueue.new()

    if warp do
      Process.send_after(self(), :request_manifest, @startup_delay)
    else
      request_next_block(@startup_delay)
    end

    {:ok,
     %{
       chain: chain,
       block_queue: block_queue,
       warp_queue: warp_queue,
       block_tree: block_tree,
       trie: trie,
       last_requested_block: nil
     }}
  end

  defp request_next_block(timeout \\ 0) do
    Process.send_after(self(), :request_next_block, timeout)
  end

  @doc """
  When were receive a block header, we'll add it to our block queue. When we
  receive the corresponding block body, we'll add that as well.
  """
  @impl true
  def handle_info(
        :request_next_block,
        state = %{block_queue: block_queue, block_tree: block_tree}
      ) do
    new_state = handle_request_next_block(block_queue, block_tree, state)

    {:noreply, new_state}
  end

  def handle_info(:request_manifest, state) do
    new_state = handle_request_manifest(state)

    {:noreply, new_state}
  end

  def handle_info({:request_block_chunk, chunk_hash, is_block_chunk}, state) do
    new_state = handle_request_block_chunk(chunk_hash, is_block_chunk, state)

    {:noreply, new_state}
  end

  def handle_info({:packet, %BlockHeaders{} = block_headers, peer}, state) do
    {:noreply, handle_block_headers(block_headers, peer, state)}
  end

  def handle_info({:packet, %BlockBodies{} = block_bodies, _peer}, state) do
    {:noreply, handle_block_bodies(block_bodies, state)}
  end

  def handle_info({:packet, %SnapshotManifest{} = snapshot_manifest, peer}, state) do
    {:noreply, handle_snapshot_manifest(snapshot_manifest, peer, state)}
  end

  def handle_info({:packet, %SnapshotData{} = snapshot_data, peer}, state) do
    {:noreply, handle_snapshot_data(snapshot_data, peer, state)}
  end

  def handle_info({:packet, packet, peer}, state) do
    :ok = Exth.trace(fn -> "[Sync] Ignoring packet #{packet.__struct__} from #{peer}" end)

    {:noreply, state}
  end

  @doc """
  Dispatches a packet of `GetSnapshotManifest` to all capable peers.

  # TODO: That "capable peers" part.
  """
  @spec handle_request_manifest(state()) :: state()
  def handle_request_manifest(state) do
    if send_with_retry(%GetSnapshotManifest{}, :all, :request_manifest) do
      :ok = Logger.debug(fn -> "[Sync] Requested snapshot manifests" end)
    end

    state
  end

  @doc """
  Dispatches a packet of `GetSnapshotData` to a random capable peer.

  # TODO: That "capable peer" part.
  """
  @spec handle_request_block_chunk(EVM.hash(), boolean(), state()) :: state()
  def handle_request_block_chunk(chunk_hash, is_block_chunk, state) do
    if send_with_retry(
         %GetSnapshotData{chunk_hash: chunk_hash},
         :random,
         {:request_block_chunk, is_block_chunk, chunk_hash}
       ) do
      :ok = Logger.debug("Requested block chunk #{Exth.encode_hex(chunk_hash)}...")
    end

    state
  end

  @doc """
  Dispatches a packet of `GetBlockHeaders` to a peer for the next block
  number that we don't have in our block queue or state tree.
  """
  @spec handle_request_next_block(BlockQueue.t(), Blocktree.t(), state()) :: state()
  def handle_request_next_block(block_queue, block_tree, state) do
    next_block_to_request = get_next_block_to_request(block_queue, block_tree)

    if send_with_retry(
         %GetBlockHeaders{
           block_identifier: next_block_to_request,
           max_headers: @blocks_per_request,
           skip: 0,
           reverse: false
         },
         :random,
         :request_next_block
       ) do
      :ok = Logger.debug(fn -> "[Sync] Requested block #{next_block_to_request}" end)

      Map.put(state, :last_requested_block, next_block_to_request + @blocks_per_request)
    else
      state
    end
  end

  @doc """
  When we receive a new snapshot manifest, we add it to our warp queue. We may
  have new blocks to fetch, so we ask the warp queue for more blocks to
  request. We may already, however, be waiting on blocks, in which case we
  do nothing.
  """
  @spec handle_snapshot_manifest(SnapshotManifest.t(), Peer.t(), state()) :: state()
  def handle_snapshot_manifest(%SnapshotManifest{manifest: nil}, _peer, state) do
    :ok = Logger.debug("Received nil snapshot manifest")

    state
  end

  def handle_snapshot_manifest(
        %SnapshotManifest{manifest: manifest},
        _peer,
        state = %{
          warp_queue: warp_queue,
          block_tree: block_tree,
          trie: trie
        }
      ) do
    {next_warp_queue, next_block_tree, next_trie} =
      warp_queue
      |> WarpQueue.new_manifest(manifest)
      |> dispatch_new_warp_queue_requests()
      |> WarpQueue.process_completed_blocks(block_tree, trie)

    %{
      state
      | warp_queue: next_warp_queue,
        block_tree: next_block_tree,
        trie: next_trie
    }
  end

  @spec dispatch_new_warp_queue_requests(WarpQueue.t(), integer()) :: WarpQueue.t()
  defp dispatch_new_warp_queue_requests(warp_queue, request_limit \\ @request_limit) do
    {new_warp_queue, block_hashes_to_request} =
      WarpQueue.get_block_hashes_to_request(warp_queue, request_limit)

    for block_hash <- block_hashes_to_request do
      request_block_chunk(block_hash, true)
    end

    new_warp_queue
  end

  @doc """
  When we receive a SnapshotData, let's try to add the received block to the
  warp queue. We may decide to request new blocks at this time.
  """
  @spec handle_snapshot_data(SnapshotData.t(), Peer.t(), state()) :: state()
  def handle_snapshot_data(%SnapshotData{chunk: nil}, _peer, state) do
    :ok = Logger.debug("Received empty SnapshotData message.")

    state
  end

  def handle_snapshot_data(
        %SnapshotData{hash: block_chunk_hash, chunk: block_chunk = %BlockChunk{}},
        _peer,
        state = %{warp_queue: warp_queue, block_tree: block_tree, trie: trie}
      ) do
    {next_warp_queue, next_block_tree, next_trie} =
      warp_queue
      |> WarpQueue.new_block_chunk(block_chunk_hash, block_chunk)
      |> dispatch_new_warp_queue_requests()
      |> WarpQueue.process_completed_blocks(block_tree, trie)

    %{
      state
      | warp_queue: next_warp_queue,
        block_tree: next_block_tree,
        trie: next_trie
    }
  end

  def handle_snapshot_data(
        %SnapshotData{chunk: state_chunk = %StateChunk{}},
        _peer,
        state = %{warp_queue: _warp_queue}
      ) do
    Exth.inspect(state_chunk, "Got state_chunk, not doing what I should")

    # WarpQueue.new_block_chunk(warp_queue, block_chunk)

    state
  end

  @doc """
  When we get block headers from peers, we add them to our current block
  queue to incorporate the blocks into our state chain.

  Note: some blocks (esp. older ones or on test nets) may be empty, and thus
        we won't need to request the bodies. These we process right away.
        Otherwise, we request the block bodies for the blocks we don't
        know about.

  Note: we process blocks in memory and save our state tree every so often.
  Note: this mimics a lot of the logic from block bodies since a header
        of an empty block *is* a complete block.
  """
  @spec handle_block_headers(BlockHeaders.t(), Peer.t(), state()) :: state()
  def handle_block_headers(
        block_headers,
        peer,
        state = %{
          block_queue: block_queue,
          block_tree: block_tree,
          chain: chain,
          trie: trie
        }
      ) do
    {next_block_queue, next_block_tree, next_trie, header_hashes} =
      Enum.reduce(block_headers.headers, {block_queue, block_tree, trie, []}, fn header,
                                                                                 {block_queue,
                                                                                  block_tree,
                                                                                  trie,
                                                                                  header_hashes} ->
        header_hash = header |> Header.hash()

        {next_block_queue, next_block_tree, next_trie, should_request_block} =
          BlockQueue.add_header(
            block_queue,
            block_tree,
            header,
            header_hash,
            peer.remote_id,
            chain,
            trie
          )

        next_header_hashes =
          if should_request_block do
            :ok = Logger.debug(fn -> "[Sync] Requesting block body #{header.number}" end)

            [header_hash | header_hashes]
          else
            header_hashes
          end

        {next_block_queue, next_block_tree, next_trie, next_header_hashes}
      end)

    :ok =
      PeerSupervisor.send_packet(
        %GetBlockBodies{
          hashes: header_hashes
        },
        :random
      )

    next_maybe_saved_trie = maybe_save(block_tree, next_block_tree, next_trie)
    :ok = maybe_request_next_block(next_block_queue)

    state
    |> Map.put(:block_queue, next_block_queue)
    |> Map.put(:block_tree, next_block_tree)
    |> Map.put(:trie, next_maybe_saved_trie)
  end

  @doc """
  After we're given headers from peers, we request the block bodies. Here we
  try to add those blocks to our block tree. It's possbile we receive block
  `n + 1` before we receive block `n`, so in these cases, we queue up the
  blocks until we process the parent block.

  Note: we process blocks in memory and save our state tree every so often.
  """
  @spec handle_block_bodies(BlockBodies.t(), state()) :: state()
  def handle_block_bodies(
        block_bodies,
        state = %{
          block_queue: block_queue,
          block_tree: block_tree,
          chain: chain,
          trie: trie
        }
      ) do
    {next_block_queue, next_block_tree, next_trie} =
      Enum.reduce(block_bodies.blocks, {block_queue, block_tree, trie}, fn block_body,
                                                                           {block_queue,
                                                                            block_tree, trie} ->
        BlockQueue.add_block_struct(block_queue, block_tree, block_body, chain, trie)
      end)

    next_maybe_saved_trie = maybe_save(block_tree, next_block_tree, next_trie)
    :ok = maybe_request_next_block(next_block_queue)

    state
    |> Map.put(:block_queue, next_block_queue)
    |> Map.put(:block_tree, next_block_tree)
    |> Map.put(:trie, next_maybe_saved_trie)
  end

  # Determines the next block we don't yet have in our blocktree and
  # dispatches a request to all connected peers for that block and the
  # next `n` blocks after it.
  @spec get_next_block_to_request(BlockQueue.t(), Blocktree.t()) :: integer()
  defp get_next_block_to_request(block_queue, block_tree) do
    # This is the best we know about
    next_number =
      case block_tree.best_block do
        nil -> 0
        %Block{header: %Header{number: number}} -> number + 1
      end

    # But we may have it queued up already in the block queue, let's
    # start from the first we *don't* know about. It's possible there's
    # holes in block queue, so it's not `max(best_block.number, max(keys(queue)))`,
    # though it could be...
    next_number
    |> Stream.iterate(fn n -> n + 1 end)
    |> Stream.reject(fn n -> MapSet.member?(block_queue.block_numbers, n) end)
    |> Enum.at(0)
  end

  @spec maybe_save(Blocktree.t(), Blocktree.t(), Trie.t()) :: Trie.t()
  defp maybe_save(block_tree, next_block_tree, trie) do
    if block_tree != next_block_tree do
      maybe_save_sync_state(next_block_tree, trie)
    else
      trie
    end
  end

  @spec request_block_chunk(EVM.hash(), boolean()) :: reference()
  defp request_block_chunk(chunk_hash, is_block_chunk) do
    Process.send_after(self(), {:request_block_chunk, chunk_hash, is_block_chunk}, 0)
  end

  @spec maybe_request_next_block(BlockQueue.t()) :: :ok
  defp maybe_request_next_block(block_queue) do
    # Let's pull a new block if we have none left
    _ =
      if block_queue.queue == %{} do
        request_next_block()
      end

    :ok
  end

  # Loads sync state from our backing database
  @spec load_sync_state(Chain.t()) :: {Blocktree.t(), CachingTrie.t()}
  defp load_sync_state(chain) do
    db = RocksDB.init(Config.db_name(chain))

    trie =
      db
      |> Trie.new()
      |> CachingTrie.new()

    blocktree = State.load_tree(db)

    {blocktree, trie}
  end

  # Save sync state from our backing database if the most recently
  # added block is a multiple of our block save interval.
  @spec maybe_save_sync_state(Blocktree.t(), Trie.t()) :: Trie.t()
  defp maybe_save_sync_state(blocktree, trie) do
    block_number = blocktree.best_block.header.number

    if rem(block_number, @save_block_interval) == 0 do
      committed_trie = TrieStorage.commit!(trie)

      committed_trie
      |> TrieStorage.permanent_db()
      |> State.save_tree(blocktree)

      committed_trie
    else
      trie
    end
  end

  @spec send_with_retry(Packet.packet(), PeerSupervisor.node_selector(), term()) :: boolean()
  defp send_with_retry(packet, node_selector, retry_message) do
    send_packet_result =
      PeerSupervisor.send_packet(
        packet,
        node_selector
      )

    case send_packet_result do
      :ok ->
        true

      :unsent ->
        :ok =
          Logger.debug(fn ->
            "[Sync] No connected peers to send #{packet.__struct__}, trying again in #{
              @retry_delay / 1000
            } second(s)"
          end)

        Process.send_after(self(), retry_message, @retry_delay)

        false
    end
  end
end
