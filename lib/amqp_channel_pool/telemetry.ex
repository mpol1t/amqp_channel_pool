defmodule AMQPChannelPool.Telemetry do
  @moduledoc false

  @metadata_keys [:pool, :worker_pid, :worker_state, :recovery_kind, :reason, :timeout, :result]

  @checkout_start [:amqp_channel_pool, :checkout, :start]
  @checkout_stop [:amqp_channel_pool, :checkout, :stop]
  @checkout_exception [:amqp_channel_pool, :checkout, :exception]

  @worker_init_start [:amqp_channel_pool, :worker, :init, :start]
  @worker_init_stop [:amqp_channel_pool, :worker, :init, :stop]
  @worker_init_exception [:amqp_channel_pool, :worker, :init, :exception]

  @worker_recover_start [:amqp_channel_pool, :worker, :recover, :start]
  @worker_recover_stop [:amqp_channel_pool, :worker, :recover, :stop]
  @worker_recover_exception [:amqp_channel_pool, :worker, :recover, :exception]

  @worker_discard [:amqp_channel_pool, :worker, :discard]
  @worker_terminate [:amqp_channel_pool, :worker, :terminate]

  def emit_checkout_start(metadata),
    do: emit(@checkout_start, %{system_time: System.system_time()}, metadata)

  def emit_checkout_stop(duration, metadata),
    do: emit(@checkout_stop, %{duration: duration}, metadata)

  def emit_checkout_exception(duration, metadata),
    do: emit(@checkout_exception, %{duration: duration}, metadata)

  def emit_worker_init_start(metadata),
    do: emit(@worker_init_start, %{system_time: System.system_time()}, metadata)

  def emit_worker_init_stop(duration, metadata),
    do: emit(@worker_init_stop, %{duration: duration}, metadata)

  def emit_worker_init_exception(duration, metadata),
    do: emit(@worker_init_exception, %{duration: duration}, metadata)

  def emit_worker_recover_start(metadata),
    do: emit(@worker_recover_start, %{system_time: System.system_time()}, metadata)

  def emit_worker_recover_stop(duration, metadata),
    do: emit(@worker_recover_stop, %{duration: duration}, metadata)

  def emit_worker_recover_exception(duration, metadata),
    do: emit(@worker_recover_exception, %{duration: duration}, metadata)

  def emit_worker_discard(metadata), do: emit(@worker_discard, %{}, metadata)
  def emit_worker_terminate(metadata), do: emit(@worker_terminate, %{}, metadata)

  defp emit(event, measurements, metadata) do
    :telemetry.execute(event, measurements, normalize_metadata(metadata))
  end

  defp normalize_metadata(metadata) do
    base =
      Enum.reduce(@metadata_keys, %{}, fn key, acc ->
        Map.put(acc, key, Map.get(metadata, key))
      end)

    Map.merge(base, metadata)
  end
end
