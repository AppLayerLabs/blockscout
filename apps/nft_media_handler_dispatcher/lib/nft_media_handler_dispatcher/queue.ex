defmodule NFTMediaHandlerDispatcher.Queue do
  @moduledoc """
  Queue for fetching media
  """

  use GenServer

  require Logger
  alias Explorer.Chain.Token.Instance
  alias Explorer.Prometheus.Instrumenter
  alias Explorer.Token.MetadataRetriever
  alias NftMediaHandlerDispatcher.Backfiller
  import NFTMediaHandlerDispatcher, only: [get_media_url_from_metadata: 1]

  @indexer_priority 0
  @backfill_priority 1

  @spec process_new_instance(any(), integer()) :: :ignore | :ok
  def process_new_instance(nft, priority \\ @indexer_priority)

  def process_new_instance({:ok, %Instance{} = nft}, priority) do
    url = get_media_url_from_metadata(nft.metadata |> dbg()) |> dbg()

    if url do
      GenServer.cast(__MODULE__, {:add_to_queue, {nft.token_contract_address_hash, nft.token_id, url, priority}})
    else
      :ignore
    end
  end

  def process_new_instance(_, _priority), do: :ignore

  def get_urls_to_fetch(amount) do
    GenServer.call(__MODULE__, {:get_urls_to_fetch, amount})
  end

  def store_result({:error, reason}, url) do
    GenServer.cast(__MODULE__, {:handle_error, url, reason})
  end

  def store_result({:down, reason}, url) do
    dbg("down_reason")
    dbg()
    GenServer.cast(__MODULE__, {:handle_error, url, reason})
  end

  def store_result({result, media_type}, url) do
    dbg("store result")
    dbg()
    GenServer.cast(__MODULE__, {:finished, result, url, media_type})
  end

  def start_link(_) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  # todo: close dets if needed
  def init(_) do
    {:ok, queue} = :dets.open_file(:queue_storage, type: :bag)
    {:ok, in_progress} = :dets.open_file(:tasks_in_progress, type: :set)

    {:ok, {queue, in_progress, nil}}
  end

  def handle_cast(
        {:add_to_queue, {token_address_hash, token_id, media_url, priority}},
        {queue, in_progress, continuation}
      ) do
    :dets.insert(queue, {media_url, {token_address_hash, token_id, priority}})

    {:noreply, {queue, in_progress, continuation}}
  end

  def handle_cast({:finished, result, url, media_type}, {_queue, in_progress, _continuation} = state)
      when is_map(result) do
    now = System.monotonic_time()

    [{_, instances, start_time}] = :dets.lookup(in_progress, url)

    :dets.delete(in_progress, url)

    Instrumenter.increment_successfully_uploaded_media_number()
    Instrumenter.media_processing_time(System.convert_time_unit(now - start_time, :native, :millisecond) / 1000)

    Enum.map(instances, fn instance_identifier ->
      Instance.set_media_urls(instance_identifier, result, media_type)
    end)

    {:noreply, state}
  end

  def handle_cast({:handle_error, url, reason}, {_queue, in_progress, _continuation} = state) do
    [{_, instances, _start_time}] = :dets.lookup(in_progress, url)

    :dets.delete(in_progress, url)

    Instrumenter.increment_failed_uploading_media_number()

    Enum.map(instances, fn instance_identifier ->
      Instance.set_cdn_upload_error(instance_identifier, reason |> inspect() |> MetadataRetriever.truncate_error())
    end)

    {:noreply, state}
  end

  def handle_call({:get_by_url, url}, _from, {queue, _in_progress, _continuation} = state) do
    {:reply, :dets.lookup(queue, url), state}
  end

  def handle_call({:get_urls_to_fetch, amount}, _from, {queue, in_progress, continuation}) do
    {high_priority_urls, continuation} = fetch_urls_from_dets(queue, amount, continuation, @indexer_priority)
    now = System.monotonic_time()

    high_priority_instances = fetch_and_delete_instances_from_queue(queue, high_priority_urls, now)

    taken_amount = Enum.count(high_priority_urls)

    {urls, instances} =
      if taken_amount < amount do
        backfill_items = Backfiller.get_instances(amount - taken_amount)

        {low_priority_instances, low_priority_urls} =
          Enum.map_reduce(backfill_items, [], fn {url, instances}, acc ->
            {{url, instances, now}, [url | acc]}
          end)

        {high_priority_urls ++ low_priority_urls, high_priority_instances ++ low_priority_instances}
      end

    :dets.insert(in_progress, instances)
    {:reply, urls, {queue, in_progress, continuation}}
  end

  defp fetch_urls_from_dets(queue_table, amount, continuation, priority) do
    query = {:"$1", {:_, :_, priority}}

    result =
      if is_nil(continuation) do
        :dets.match(queue_table, query, amount)
      else
        :dets.match(continuation)
      end

    case result do
      {:error, reason} ->
        Logger.error("Failed to fetch urls from dets: #{inspect(reason)}")
        {[], nil}

      :"$end_of_table" ->
        {[], nil}

      {urls, :"$end_of_table"} ->
        {urls |> List.flatten() |> Enum.uniq(), nil}

      {urls, continuation} ->
        {urls |> List.flatten() |> Enum.uniq(), continuation}
    end
  end

  defp fetch_and_delete_instances_from_queue(queue, urls, start_time) do
    Enum.map(urls, fn url ->
      instances =
        :dets.lookup(queue, url)
        |> Enum.map(fn {_url, {address_hash, token_id, _priority}} -> {address_hash, token_id} end)

      :dets.delete(queue, url)

      {url, instances, start_time}
    end)
  end
end
