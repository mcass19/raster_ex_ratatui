defmodule RasterExRatatui.Surface.Server do
  @moduledoc false

  # The process behind `use RasterExRatatui.Surface`. See that moduledoc
  # for the lifecycle; this module only adds what a process adds to a
  # `RasterExRatatui.Session`: the consumer's callbacks, `min_interval`,
  # the push, telemetry, and the exit policy.
  #
  # Renders are folded, not queued. When a diff arrives, every diff already
  # waiting in the mailbox is taken with it (`Session.drain/2`), and the
  # whole batch goes through one `Session.render/2` and one push, right
  # away. So when the app renders faster than the surface rasterises or
  # the panel writes, the surface shows fewer, later frames instead of
  # every frame later and later, and a key event never waits behind stale
  # renders. `min_interval` holds the batch back on a timer instead;
  # nothing is rasterised until the push is due.

  use GenServer

  require Logger

  alias RasterExRatatui.{Raster, Session, Telemetry}

  @raster_keys [:size, :font, :format, :scale, :rotate, :format_opts]

  defstruct [
    :module,
    :state,
    :app,
    :session,
    :session_opts,
    :push_mode,
    :min_interval,
    :on_app_exit,
    :max_restarts,
    :max_seconds,
    crashes: [],
    timer: nil,
    last_push: nil,
    pending: []
  ]

  @impl true
  def init({module, opts}) do
    Process.flag(:trap_exit, true)

    case module.init(opts) do
      {:ok, config, state} when is_list(config) ->
        start(module, Keyword.merge(opts, config), state)

      {:stop, reason} ->
        {:stop, reason}

      other ->
        raise ArgumentError,
              "expected #{inspect(module)}.init/1 to return {:ok, opts, state} or {:stop, reason}, got: #{inspect(other)}"
    end
  end

  defp start(module, opts, state) do
    app = Keyword.fetch!(opts, :app)
    push_mode = Keyword.get(opts, :push_mode, :patches)
    min_interval = Keyword.get(opts, :min_interval, 0)
    shutdown_timeout = Keyword.get(opts, :shutdown_timeout, 4_000)
    on_app_exit = Keyword.get(opts, :on_app_exit, :stop)
    max_restarts = Keyword.get(opts, :max_restarts, 3)
    max_seconds = Keyword.get(opts, :max_seconds, 5)

    validate!(:push_mode, push_mode, push_mode in [:patches, :frame], ":patches or :frame")
    validate!(:on_app_exit, on_app_exit, on_app_exit in [:stop, :restart], ":stop or :restart")

    validate!(
      :max_restarts,
      max_restarts,
      non_neg_integer?(max_restarts),
      "a non-negative integer"
    )

    validate!(:max_seconds, max_seconds, pos_integer?(max_seconds), "a positive integer")

    validate!(
      :min_interval,
      min_interval,
      non_neg_integer?(min_interval),
      "a non-negative integer"
    )

    validate!(
      :shutdown_timeout,
      shutdown_timeout,
      non_neg_integer?(shutdown_timeout),
      "a non-negative integer"
    )

    raster = opts |> Keyword.take(@raster_keys) |> Raster.new()

    session_opts = [
      app: app,
      app_opts: Keyword.get(opts, :app_opts, []),
      keep_frame: push_mode == :frame,
      shutdown_timeout: shutdown_timeout
    ]

    case Session.start(raster, session_opts) do
      {:ok, session} ->
        s = %__MODULE__{
          module: module,
          state: state,
          app: app,
          session: session,
          session_opts: session_opts,
          push_mode: push_mode,
          min_interval: min_interval,
          on_app_exit: on_app_exit,
          max_restarts: max_restarts,
          max_seconds: max_seconds
        }

        start_meta = %{size: Raster.size(raster), grid_size: Raster.grid_size(raster)}
        Telemetry.execute([:surface, :start], %{}, Map.merge(meta(s), start_meta))

        {:ok, s}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_info({__MODULE__, :flush}, %__MODULE__{} = s) do
    {:noreply, flush(%{s | timer: nil})}
  end

  def handle_info(msg, %__MODULE__{} = s) do
    case Session.drain(s.session, msg) do
      {:diffs, diffs, session} ->
        s = %{s | session: session, pending: Enum.reverse(diffs, s.pending)}
        {:noreply, maybe_flush(s)}

      {:exit, reason, session} ->
        app_exit(%{s | session: session}, reason)

      :unknown ->
        consumer_info(msg, s)
    end
  end

  # The app is gone, and its server closed the cell session on the way out.
  # With `on_app_exit: :restart` a new app starts on a fresh session over
  # the same raster; its first render is a full payload, so the panel is
  # repainted. Whatever the old app had left pending is dropped.
  #
  # Restarts happen inside this process, where the supervisor cannot count
  # them, so crashes are counted here the way a supervisor would: more than
  # `max_restarts` within `max_seconds` and the surface stops with the
  # app's reason, handing the loop to the real supervisor. An app that
  # quits on purpose (a `:normal` or `:shutdown` exit) always comes back.
  defp app_exit(%__MODULE__{on_app_exit: :restart} = s, reason) do
    s = count_crash(s, reason)

    if length(s.crashes) > s.max_restarts do
      Logger.error(
        "#{inspect(s.module)}: #{inspect(s.app)} crashed #{length(s.crashes)} times in #{s.max_seconds} s, stopping the surface"
      )

      stop_on_exit(s, reason)
    else
      restart(s, reason)
    end
  end

  defp app_exit(%__MODULE__{} = s, reason), do: stop_on_exit(s, reason)

  defp restart(%__MODULE__{} = s, reason) do
    Telemetry.execute([:app, :exit], %{}, Map.merge(meta(s), %{reason: reason, action: :restart}))

    Logger.info(
      "#{inspect(s.module)}: #{inspect(s.app)} exited with #{inspect(reason)}, starting it again"
    )

    :ok = Session.stop(s.session)

    case Session.start(Session.raster(s.session), s.session_opts) do
      {:ok, session} -> {:noreply, %{s | session: session, pending: []}}
      {:error, reason} -> {:stop, reason, s}
    end
  end

  defp stop_on_exit(%__MODULE__{} = s, reason) do
    Telemetry.execute([:app, :exit], %{}, Map.merge(meta(s), %{reason: reason, action: :stop}))
    {:stop, reason, s}
  end

  # The crashes within the window, newest first; a deliberate exit is none.
  defp count_crash(%__MODULE__{} = s, reason) when reason in [:normal, :shutdown], do: s
  defp count_crash(%__MODULE__{} = s, {:shutdown, _}), do: s

  defp count_crash(%__MODULE__{} = s, _reason) do
    now = System.monotonic_time(:millisecond)
    window = s.max_seconds * 1_000
    %{s | crashes: [now | Enum.filter(s.crashes, &(now - &1 < window))]}
  end

  defp consumer_info(msg, %__MODULE__{module: module} = s) do
    case module.handle_info(msg, s.state) do
      {:noreply, state} ->
        {:noreply, %{s | state: state}}

      {:events, events, state} ->
        Enum.each(events, &forward(s, &1))
        {:noreply, %{s | state: state}}
    end
  end

  @impl true
  def handle_cast({:event, event}, %__MODULE__{} = s) do
    forward(s, event)
    {:noreply, s}
  end

  @impl true
  def handle_call({:resize, size}, _from, %__MODULE__{} = s) do
    session = Session.resize(s.session, size)
    {:reply, Session.grid_size(session), %{s | session: session, pending: []}}
  end

  def handle_call(:server, _from, %__MODULE__{} = s), do: {:reply, Session.server(s.session), s}
  def handle_call(:raster, _from, %__MODULE__{} = s), do: {:reply, Session.raster(s.session), s}

  @impl true
  def terminate(reason, %__MODULE__{} = s) do
    :ok = Session.stop(s.session)

    Telemetry.execute([:surface, :stop], %{}, Map.put(meta(s), :reason, reason))
    s.module.terminate(reason, s.state)
  end

  defp forward(%__MODULE__{} = s, event) do
    :ok = Session.send_event(s.session, event)
    Telemetry.execute([:input, :forward], %{}, Map.put(meta(s), :event, event))
  end

  # Pushes as soon as the interval since the last push allows; otherwise a
  # timer, at most one, flushes what has gathered by then.
  defp maybe_flush(%__MODULE__{timer: nil} = s) do
    wait =
      case s.last_push do
        nil -> 0
        last_push -> last_push + s.min_interval - System.monotonic_time(:millisecond)
      end

    if wait > 0 do
      %{s | timer: Process.send_after(self(), {__MODULE__, :flush}, wait)}
    else
      flush(s)
    end
  end

  defp maybe_flush(%__MODULE__{} = s), do: s

  # A resize drops the pending diffs; a flush already on its way then has
  # nothing to do.
  defp flush(%__MODULE__{pending: []} = s), do: s

  defp flush(%__MODULE__{} = s) do
    diffs = Enum.reverse(s.pending)

    {patches, session} =
      Telemetry.span([:frame, :raster], meta(s), fn ->
        {patches, session} = Session.render(s.session, diffs)

        # Only diffs get here: `Session.drain/2` admits nothing else.
        stop = %{
          diffs: length(diffs),
          cells: diffs |> Enum.map(&length(&1.ops)) |> Enum.sum(),
          regions: length(List.last(diffs).regions),
          patches: length(patches)
        }

        {{patches, session}, stop}
      end)

    s = %{s | session: session, pending: []}

    case {patches, s.push_mode} do
      {[], _mode} -> s
      {patches, :patches} -> do_push(s, patches)
      {_patches, :frame} -> do_push(s, {:frame, Session.frame(session)})
    end
  end

  defp do_push(%__MODULE__{} = s, pixels) do
    state =
      Telemetry.span([:frame, :push], Map.put(meta(s), :push_mode, s.push_mode), fn ->
        {s.module.push(pixels, s.state), %{}}
      end)

    %{s | state: state, last_push: System.monotonic_time(:millisecond)}
  end

  defp validate!(_key, _value, true, _expected), do: :ok

  defp validate!(key, value, false, expected) do
    raise ArgumentError, "expected #{inspect(key)} to be #{expected}, got: #{inspect(value)}"
  end

  defp non_neg_integer?(value), do: is_integer(value) and value >= 0
  defp pos_integer?(value), do: is_integer(value) and value > 0

  defp meta(%__MODULE__{} = s), do: %{surface: s.module, mod: s.app, pid: self()}
end
