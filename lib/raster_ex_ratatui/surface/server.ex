defmodule RasterExRatatui.Surface.Server do
  @moduledoc false

  # The process behind `use RasterExRatatui.Surface`. See that moduledoc
  # for the lifecycle; this module only implements it.
  #
  # Renders are folded, not queued. When a diff arrives, every diff already
  # waiting in the mailbox is taken with it, and the whole batch goes
  # through one `Raster.apply/2` and one push, right away. So when the app
  # renders faster than the surface rasterises or the panel writes, the
  # surface shows fewer, later frames instead of every frame later and
  # later, and a key event never waits behind stale renders. `min_interval`
  # holds the batch back on a timer instead; nothing is rasterised until
  # the push is due.

  use GenServer

  require Logger

  alias ExRatatui.CellSession
  alias ExRatatui.CellSession.Diff
  alias RasterExRatatui.{Raster, Telemetry}

  @raster_keys [:size, :font, :format, :scale, :format_opts]

  defstruct [
    :module,
    :state,
    :app,
    :app_opts,
    :raster,
    :session,
    :server,
    :push_mode,
    :min_interval,
    :shutdown_timeout,
    :on_app_exit,
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

    validate!(:push_mode, push_mode, push_mode in [:patches, :frame], ":patches or :frame")
    validate!(:on_app_exit, on_app_exit, on_app_exit in [:stop, :restart], ":stop or :restart")

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
    session = new_session(raster)

    surface_state = %__MODULE__{
      module: module,
      state: state,
      app: app,
      app_opts: Keyword.get(opts, :app_opts, []),
      raster: raster,
      session: session,
      push_mode: push_mode,
      min_interval: min_interval,
      shutdown_timeout: shutdown_timeout,
      on_app_exit: on_app_exit
    }

    case start_server(surface_state) do
      {:ok, surface_state} ->
        start_meta = %{size: Raster.size(raster), grid_size: Raster.grid_size(raster)}
        Telemetry.execute([:surface, :start], %{}, Map.merge(meta(surface_state), start_meta))

        {:ok, surface_state}

      {:error, reason} ->
        CellSession.close(session)
        {:stop, reason}
    end
  end

  defp new_session(%Raster{} = raster) do
    {cols, rows} = Raster.grid_size(raster)
    CellSession.new(cols, rows, font_size: Raster.font_size(raster))
  end

  # Starts the app server on the surface's session, linked. Its `mount/1`
  # sees `surface:` in its options: the panel as the raster knows it.
  defp start_server(%__MODULE__{} = s) do
    surface = self()

    writer = fn diff ->
      send(surface, {__MODULE__, :diff, diff})
      :ok
    end

    server_opts =
      [mod: s.app, name: nil, transport: {:cell_session, s.session, writer}] ++
        Keyword.put(s.app_opts, :surface, surface_info(s.raster))

    case ExRatatui.Transport.start_server(server_opts) do
      {:ok, server} -> {:ok, %{s | server: server}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp surface_info(%Raster{} = raster) do
    %{
      size: Raster.size(raster),
      cell_size: Raster.font_size(raster),
      grid_size: Raster.grid_size(raster),
      format: raster.format,
      scale: raster.scale,
      rotate: 0
    }
  end

  @impl true
  def handle_info({__MODULE__, :diff, %Diff{} = diff}, %__MODULE__{} = s) do
    diffs = Enum.filter([diff | drain()], &current?(&1, s))
    {:noreply, maybe_flush(%{s | pending: Enum.reverse(diffs, s.pending)})}
  end

  def handle_info({__MODULE__, :flush}, %__MODULE__{} = s) do
    {:noreply, flush(%{s | timer: nil})}
  end

  # The app is gone, and its server closed the cell session on the way out.
  # With `on_app_exit: :restart` a new app starts on a fresh session over
  # the same raster; its first render is a full payload, so the panel is
  # repainted. Whatever the old app had left pending is dropped.
  def handle_info({:EXIT, server, reason}, %__MODULE__{server: server, on_app_exit: :restart} = s) do
    app_exit(s, reason, :restart)

    Logger.info(
      "#{inspect(s.module)}: #{inspect(s.app)} exited with #{inspect(reason)}, starting it again"
    )

    s = %{s | server: nil, session: new_session(s.raster), pending: []}

    case start_server(s) do
      {:ok, s} -> {:noreply, s}
      {:error, reason} -> {:stop, reason, s}
    end
  end

  def handle_info({:EXIT, server, reason}, %__MODULE__{server: server} = s) do
    app_exit(s, reason, :stop)
    {:stop, reason, %{s | server: nil}}
  end

  def handle_info(msg, %__MODULE__{module: module} = s) do
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
    raster = Raster.resize(s.raster, size)
    {cols, rows} = Raster.grid_size(raster)
    :ok = CellSession.resize(s.session, cols, rows)
    send(s.server, {:ex_ratatui_resize, cols, rows})
    {:reply, {cols, rows}, %{s | raster: raster, pending: []}}
  end

  def handle_call(:server, _from, %__MODULE__{} = s), do: {:reply, s.server, s}
  def handle_call(:raster, _from, %__MODULE__{} = s), do: {:reply, s.raster, s}

  @impl true
  def terminate(reason, %__MODULE__{} = s) do
    stop_server(s.server, s.shutdown_timeout)

    Telemetry.execute([:surface, :stop], %{}, Map.put(meta(s), :reason, reason))
    s.module.terminate(reason, s.state)
    CellSession.close(s.session)
  end

  defp stop_server(nil, _timeout), do: :ok

  # The server is linked and we trap exits, so its exit arrives as a message.
  # Its terminate/2 closes the session and runs the app's terminate/2; if that
  # hangs, the server is killed so the consumer's terminate/2 still runs
  # within the supervisor's shutdown budget.
  defp stop_server(server, timeout) do
    Process.exit(server, :shutdown)

    receive do
      {:EXIT, ^server, _reason} -> :ok
    after
      timeout ->
        Process.exit(server, :kill)

        receive do
          {:EXIT, ^server, _reason} -> :ok
        end
    end
  end

  defp app_exit(%__MODULE__{} = s, reason, action) do
    Telemetry.execute([:app, :exit], %{}, Map.merge(meta(s), %{reason: reason, action: action}))
  end

  defp forward(%__MODULE__{} = s, event) do
    send(s.server, {:ex_ratatui_event, event})
    Telemetry.execute([:input, :forward], %{}, Map.put(meta(s), :event, event))
  end

  # Every diff already in the mailbox, oldest first.
  defp drain do
    receive do
      {__MODULE__, :diff, %Diff{} = diff} -> [diff | drain()]
    after
      0 -> []
    end
  end

  # A diff rendered before a resize arrives with the old dimensions; the
  # next render repaints the new grid in full, so it is dropped.
  defp current?(%Diff{width: w, height: h}, %__MODULE__{raster: %Raster{grid_size: size}}),
    do: {w, h} == size

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

    {raster, patches} =
      Telemetry.span([:frame, :raster], meta(s), fn ->
        {raster, patches} = Raster.apply(s.raster, diffs)

        stop = %{
          diffs: length(diffs),
          cells: diffs |> Enum.map(&length(&1.ops)) |> Enum.sum(),
          regions: length(List.last(diffs).regions),
          patches: length(patches)
        }

        {{raster, patches}, stop}
      end)

    s = %{s | raster: raster, pending: []}

    case {patches, s.push_mode} do
      {[], _mode} ->
        s

      {patches, :patches} ->
        do_push(s, patches)

      {_patches, :frame} ->
        {raster, frame} = Raster.render_frame(s.raster)
        do_push(%{s | raster: raster}, {:frame, frame})
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

  defp meta(%__MODULE__{} = s), do: %{surface: s.module, mod: s.app, pid: self()}
end
