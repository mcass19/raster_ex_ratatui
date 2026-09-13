defmodule RasterExRatatui.Surface.Server do
  @moduledoc false

  # The process behind `use RasterExRatatui.Surface`. See that moduledoc
  # for the lifecycle; this module only implements it.
  #
  # Pushes are coalesced: every diff is rasterised as it arrives, but the
  # push goes through a self-sent flush message scheduled at most once. When
  # push/2 is slower than the app renders, the diffs that arrive during a
  # push queue ahead of the next flush, and all of them go out in one push.

  use GenServer

  alias ExRatatui.CellSession
  alias ExRatatui.CellSession.Diff
  alias RasterExRatatui.{Raster, Telemetry}

  @raster_keys [:size, :font, :format, :scale, :format_opts]

  defstruct [
    :module,
    :state,
    :app,
    :raster,
    :session,
    :server,
    :push_mode,
    :min_interval,
    :shutdown_timeout,
    flush_scheduled: false,
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
    end
  end

  defp start(module, opts, state) do
    app = Keyword.fetch!(opts, :app)
    push_mode = Keyword.get(opts, :push_mode, :patches)
    min_interval = Keyword.get(opts, :min_interval, 0)
    shutdown_timeout = Keyword.get(opts, :shutdown_timeout, 4_000)

    validate!(:push_mode, push_mode, push_mode in [:patches, :frame], ":patches or :frame")

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
    {cols, rows} = Raster.grid_size(raster)
    session = CellSession.new(cols, rows, font_size: Raster.font_size(raster))
    surface = self()

    writer = fn diff ->
      send(surface, {__MODULE__, :diff, diff})
      :ok
    end

    server_opts =
      [mod: app, name: nil, transport: {:cell_session, session, writer}] ++
        Keyword.get(opts, :app_opts, [])

    case ExRatatui.Transport.start_server(server_opts) do
      {:ok, server} ->
        surface_state = %__MODULE__{
          module: module,
          state: state,
          app: app,
          raster: raster,
          session: session,
          server: server,
          push_mode: push_mode,
          min_interval: min_interval,
          shutdown_timeout: shutdown_timeout
        }

        start_meta = %{size: Raster.size(raster), grid_size: {cols, rows}}
        Telemetry.execute([:surface, :start], %{}, Map.merge(meta(surface_state), start_meta))

        {:ok, surface_state}

      {:error, reason} ->
        CellSession.close(session)
        {:stop, reason}
    end
  end

  @impl true
  # A diff rendered before a resize arrives with the old dimensions; the
  # next render repaints the new grid in full, so it is dropped.
  def handle_info(
        {__MODULE__, :diff, %Diff{width: w, height: h}},
        %__MODULE__{raster: %Raster{grid_size: grid_size}} = s
      )
      when {w, h} != grid_size do
    {:noreply, s}
  end

  def handle_info({__MODULE__, :diff, %Diff{} = diff}, %__MODULE__{} = s) do
    {raster, patches} =
      Telemetry.span([:frame, :raster], meta(s), fn ->
        {raster, patches} = Raster.apply(s.raster, diff)
        stop = %{cells: length(diff.ops), regions: length(diff.regions), patches: length(patches)}
        {{raster, patches}, stop}
      end)

    case patches do
      [] -> {:noreply, %{s | raster: raster}}
      patches -> {:noreply, schedule_flush(%{s | raster: raster, pending: [patches | s.pending]})}
    end
  end

  def handle_info({__MODULE__, :flush}, %__MODULE__{} = s) do
    {:noreply, push(%{s | flush_scheduled: false})}
  end

  def handle_info({:EXIT, server, reason}, %__MODULE__{server: server} = s) do
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

  defp forward(%__MODULE__{} = s, event) do
    send(s.server, {:ex_ratatui_event, event})
    Telemetry.execute([:input, :forward], %{}, Map.put(meta(s), :event, event))
  end

  defp schedule_flush(%__MODULE__{flush_scheduled: true} = s), do: s

  defp schedule_flush(%__MODULE__{} = s) do
    wait =
      case s.last_push do
        nil -> 0
        last_push -> last_push + s.min_interval - System.monotonic_time(:millisecond)
      end

    if wait > 0 do
      Process.send_after(self(), {__MODULE__, :flush}, wait)
    else
      send(self(), {__MODULE__, :flush})
    end

    %{s | flush_scheduled: true}
  end

  # A resize drops the pending patches; a flush already on its way then has
  # nothing to push.
  defp push(%__MODULE__{pending: []} = s), do: s

  defp push(%__MODULE__{push_mode: :frame} = s) do
    {raster, frame} = Raster.render_frame(s.raster)
    do_push(%{s | raster: raster}, {:frame, frame})
  end

  defp push(%__MODULE__{} = s) do
    do_push(s, s.pending |> Enum.reverse() |> Enum.concat())
  end

  defp do_push(%__MODULE__{} = s, pixels) do
    state =
      Telemetry.span([:frame, :push], Map.put(meta(s), :push_mode, s.push_mode), fn ->
        {s.module.push(pixels, s.state), %{}}
      end)

    %{s | state: state, pending: [], last_push: System.monotonic_time(:millisecond)}
  end

  defp validate!(_key, _value, true, _expected), do: :ok

  defp validate!(key, value, false, expected) do
    raise ArgumentError, "expected #{inspect(key)} to be #{expected}, got: #{inspect(value)}"
  end

  defp non_neg_integer?(value), do: is_integer(value) and value >= 0

  defp meta(%__MODULE__{} = s), do: %{surface: s.module, mod: s.app, pid: self()}
end
