defmodule RasterExRatatui.Surface.Server do
  @moduledoc false

  # The process behind `use RasterExRatatui.Surface`. See that moduledoc
  # for the lifecycle; this module only implements it.

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
    :timer,
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

    unless push_mode in [:patches, :frame] do
      raise ArgumentError,
            "expected :push_mode to be :patches or :frame, got: #{inspect(push_mode)}"
    end

    raster = opts |> Keyword.take(@raster_keys) |> Raster.new()
    {cols, rows} = Raster.grid_size(raster)
    session = CellSession.new(cols, rows, font_size: Raster.font_size(raster))
    surface = self()

    writer = fn diff ->
      send(surface, {:raster_diff, diff})
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
          min_interval: Keyword.get(opts, :min_interval, 0)
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
  def handle_info({:raster_diff, %Diff{} = diff}, %__MODULE__{} = s) do
    {raster, patches} =
      Telemetry.span([:frame, :raster], meta(s), fn ->
        {raster, patches} = Raster.apply(s.raster, diff)
        stop = %{cells: length(diff.ops), regions: length(diff.regions), patches: length(patches)}
        {{raster, patches}, stop}
      end)

    {:noreply, schedule_push(%{s | raster: raster, pending: s.pending ++ patches})}
  end

  def handle_info(:push, %__MODULE__{} = s) do
    {:noreply, push(%{s | timer: nil})}
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
    stop_server(s.server)

    Telemetry.execute([:surface, :stop], %{}, Map.put(meta(s), :reason, reason))
    s.module.terminate(reason, s.state)
    CellSession.close(s.session)
  end

  defp stop_server(nil), do: :ok

  # The server is linked and we trap exits, so its exit arrives as a message.
  # Its terminate/2 closes the session and runs the app's terminate/2.
  defp stop_server(server) do
    Process.exit(server, :shutdown)

    receive do
      {:EXIT, ^server, _reason} -> :ok
    end
  end

  defp forward(%__MODULE__{} = s, event) do
    send(s.server, {:ex_ratatui_event, event})
    Telemetry.execute([:input, :forward], %{}, Map.put(meta(s), :event, event))
  end

  defp schedule_push(%__MODULE__{timer: timer} = s) when timer != nil, do: s

  defp schedule_push(%__MODULE__{last_push: nil} = s), do: push(s)

  defp schedule_push(%__MODULE__{} = s) do
    wait = s.last_push + s.min_interval - System.monotonic_time(:millisecond)

    if wait <= 0 do
      push(s)
    else
      %{s | timer: Process.send_after(self(), :push, wait)}
    end
  end

  defp push(%__MODULE__{pending: []} = s), do: s

  defp push(%__MODULE__{} = s) do
    pixels = if s.push_mode == :frame, do: {:frame, Raster.frame(s.raster)}, else: s.pending

    state =
      Telemetry.span([:frame, :push], Map.put(meta(s), :push_mode, s.push_mode), fn ->
        {s.module.push(pixels, s.state), %{}}
      end)

    %{s | state: state, pending: [], last_push: System.monotonic_time(:millisecond)}
  end

  defp meta(%__MODULE__{} = s), do: %{surface: s.module, mod: s.app}
end
