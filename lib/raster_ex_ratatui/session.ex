defmodule RasterExRatatui.Session do
  @moduledoc """
  An ExRatatui app running on a raster, driven from the caller's own process.

  A session is what `RasterExRatatui.Surface` wraps: the `ExRatatui.CellSession`, the app server, the writer that delivers its renders, and the `RasterExRatatui.Raster` that turns them into pixels. It has no process of its own. A consumer that already owns a process in charge of a panel (a screen manager, a device loop) starts a session in it, folds the session's messages with `handle/2`, and writes the pixels it gets back however the panel wants.

      defmodule Badge.Screen do
        use GenServer

        alias RasterExRatatui.{Raster, Session}

        def init(app) do
          Process.flag(:trap_exit, true)
          raster = Raster.new(size: {400, 300}, format: RasterExRatatui.PixelFormat.Mono)
          {:ok, session} = Session.start(raster, app: app, keep_frame: true)
          {:ok, session}
        end

        def handle_info(msg, session) do
          case Session.handle(session, msg) do
            {:render, _patches, session} ->
              Badge.Display.show(Session.frame(session))
              {:noreply, session}

            {:exit, reason, session} ->
              Badge.Display.show(crash_frame(reason))
              {:noreply, session}

            :unknown ->
              {:noreply, session}
          end
        end

        def terminate(_reason, session), do: Session.stop(session)
      end

  ## Lifecycle

  1. `start/2` creates the cell session for the raster's grid, starts the app server **linked to the caller**, and returns the session. The caller must trap exits: the app's exit then arrives as an `{:EXIT, pid, reason}` message that `handle/2` turns into `{:exit, reason, session}` instead of taking the caller down.
  2. Every render of the app arrives in the caller's mailbox as `{RasterExRatatui.Session, ref, diff}`. `handle/2` takes that message, every other render of the same session already waiting behind it, folds them into the raster as one, and returns the patches. Renders are never queued up: a slow panel shows fewer, later frames, never every frame later and later.
  3. `await/2` waits for the first render (or the app's exit) with a timeout, for consumers that want the first frame before they show anything.
  4. `stop/1` stops the app server, waiting up to `shutdown_timeout:` for its `terminate/2` before killing it, and closes the cell session.

  When the app exits, its server closes the cell session on the way out; a consumer that wants the app back starts a new session on the same raster (`start(raster(session), opts)`) and the new app's first render repaints everything.

  ## Options

  `start/2` takes:

    * `:app` (required) — the `ExRatatui.App` module to run
    * `:app_opts` — keyword list passed to the app's `mount/1` (or reducer `init/1`), default `[]`. The session adds `surface:` to it, a map describing the panel: `:size` (the physical panel in pixels), `:cell_size` (the effective cell in pixels), `:grid_size` (cells), `:format`, `:scale`, and `:rotate` (see `RasterExRatatui.Raster`'s rotation section)
    * `:keep_frame` — keep a full frame of the panel up to date (default `false`). `frame/1` then returns it at no cost, and `render/2` applies each patch to it, for panels that only take whole frames
    * `:shutdown_timeout` — milliseconds `stop/1` waits for the app server before killing it (default `4_000`)

  The pieces stay reachable: `raster/1` is the current raster (`RasterExRatatui.Raster.frame/1` renders what the panel shows), `server/1` the app server's pid, and `drain/2` and `render/2` are the two halves of `handle/2`, for a consumer that gathers renders and rasterises them on its own schedule.
  """

  alias ExRatatui.CellSession
  alias ExRatatui.CellSession.Diff
  alias RasterExRatatui.{Patch, Raster}

  @typedoc "A payload the session folds: a cell diff from the app, or a snapshot."
  @type payload :: Raster.payload()

  @type t :: %__MODULE__{
          ref: reference(),
          raster: Raster.t(),
          cell_session: CellSession.t(),
          server: pid() | nil,
          app: module(),
          frame: binary() | nil,
          shutdown_timeout: non_neg_integer()
        }

  @enforce_keys [:ref, :raster, :cell_session, :server, :app, :shutdown_timeout]
  defstruct [:ref, :raster, :cell_session, :server, :app, :frame, :shutdown_timeout]

  @doc """
  Starts an app on `raster` from the calling process (see the moduledoc for the options).

  Returns `{:ok, session}`, or `{:error, reason}` when the app fails to mount, in which case nothing is left running. Raises `ArgumentError` without an `:app`.

  The app server is linked to the caller, which must trap exits before calling this.
  """
  @spec start(Raster.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def start(%Raster{} = raster, opts) when is_list(opts) do
    app =
      Keyword.get(opts, :app) ||
        raise ArgumentError, "missing required option :app"

    shutdown_timeout = Keyword.get(opts, :shutdown_timeout, 4_000)
    keep_frame = Keyword.get(opts, :keep_frame, false)

    ref = make_ref()
    caller = self()
    cell_session = new_cell_session(raster)

    writer = fn diff ->
      send(caller, {__MODULE__, ref, diff})
      :ok
    end

    server_opts =
      [mod: app, name: nil, transport: {:cell_session, cell_session, writer}] ++
        Keyword.put(Keyword.get(opts, :app_opts, []), :surface, surface_info(raster))

    case ExRatatui.Transport.start_server(server_opts) do
      {:ok, server} ->
        session = %__MODULE__{
          ref: ref,
          raster: raster,
          cell_session: cell_session,
          server: server,
          app: app,
          shutdown_timeout: shutdown_timeout
        }

        {:ok, if(keep_frame, do: fresh_frame(session), else: session)}

      {:error, reason} ->
        CellSession.close(cell_session)
        {:error, reason}
    end
  end

  @doc """
  Handles a message from the caller's mailbox.

  Returns:

    * `{:render, patches, session}` for a render of this session's app: the `RasterExRatatui.Patch` list that repaints what changed (empty when nothing did), after folding every render of the session still waiting in the mailbox into the same call. With `keep_frame: true`, `frame/1` is up to date as well
    * `{:exit, reason, session}` when the app server exited; the session no longer has a server, and its cell session is closed
    * `:unknown` for any other message

  ## Examples

      def handle_info(msg, %{session: session} = state) do
        case RasterExRatatui.Session.handle(session, msg) do
          {:render, patches, session} -> {:noreply, %{state | session: write(patches, session)}}
          {:exit, reason, session} -> {:stop, reason, %{state | session: session}}
          :unknown -> {:noreply, state}
        end
      end
  """
  @spec handle(t(), term()) :: {:render, [Patch.t()], t()} | {:exit, term(), t()} | :unknown
  def handle(%__MODULE__{} = session, msg) do
    case drain(session, msg) do
      {:diffs, diffs, session} ->
        {patches, session} = render(session, diffs)
        {:render, patches, session}

      other ->
        other
    end
  end

  @doc """
  Waits up to `timeout` milliseconds for the next render of the session's app, or its exit, and handles it.

  Returns what `handle/2` would, or `{:timeout, session}`. Other messages stay in the mailbox. Typical right after `start/2`, for the first frame.
  """
  @spec await(t(), timeout()) ::
          {:render, [Patch.t()], t()} | {:exit, term(), t()} | {:timeout, t()}
  def await(%__MODULE__{ref: ref, server: server} = session, timeout \\ 5_000) do
    receive do
      {__MODULE__, ^ref, %Diff{}} = msg -> handle(session, msg)
      {:EXIT, ^server, _reason} = msg when is_pid(server) -> handle(session, msg)
    after
      timeout -> {:timeout, session}
    end
  end

  @doc """
  The first half of `handle/2`: classifies a message without rasterising anything.

  Returns `{:diffs, diffs, session}` for a render, with every render of the session still waiting in the mailbox gathered behind it, oldest first (renders from before a `resize/2` are dropped, since the next one repaints the new grid in full); `{:exit, reason, session}` for the app server's exit; `:unknown` otherwise. `render/2` takes the diffs whenever the consumer is ready to draw.
  """
  @spec drain(t(), term()) :: {:diffs, [Diff.t()], t()} | {:exit, term(), t()} | :unknown
  def drain(%__MODULE__{ref: ref} = session, {__MODULE__, ref, %Diff{} = diff}) do
    diffs = Enum.filter([diff | drain_mailbox(ref)], &current?(&1, session))
    {:diffs, diffs, session}
  end

  def drain(%__MODULE__{server: server} = session, {:EXIT, server, reason}) when is_pid(server) do
    {:exit, reason, %{session | server: nil}}
  end

  def drain(%__MODULE__{}, _msg), do: :unknown

  @doc """
  The second half of `handle/2`: folds `payloads` (diffs or snapshots, in order) into the raster and returns the patches that repaint what changed.

  With `keep_frame: true`, the patches are also applied to the kept frame.
  """
  @spec render(t(), [payload()]) :: {[Patch.t()], t()}
  def render(%__MODULE__{} = session, []), do: {[], session}

  def render(%__MODULE__{} = session, payloads) when is_list(payloads) do
    {raster, patches} = Raster.apply(session.raster, payloads)
    session = %{session | raster: raster}
    {patches, %{session | frame: blit(session, patches)}}
  end

  @doc """
  Forwards an `ExRatatui.Event` (a `%Key{}`, a `%Mouse{}`, …) to the app, like input from a terminal. Dropped once the app has exited.
  """
  @spec send_event(t(), ExRatatui.Event.t()) :: :ok
  def send_event(%__MODULE__{server: server}, event) when is_pid(server) do
    send(server, {:ex_ratatui_event, event})
    :ok
  end

  def send_event(%__MODULE__{server: nil}, _event), do: :ok

  @doc """
  Changes the panel size, in pixels. The raster and the cell session are rebuilt at the new grid, the app receives an `ExRatatui.Event.Resize`, and its next render repaints the whole panel.
  """
  @spec resize(t(), Raster.size()) :: t()
  def resize(%__MODULE__{} = session, {width, height} = size)
      when is_integer(width) and is_integer(height) do
    raster = Raster.resize(session.raster, size)
    {cols, rows} = Raster.grid_size(raster)

    # After the app's exit the cell session is closed; the next `start/2`
    # creates one for the new grid.
    if is_pid(session.server) do
      :ok = CellSession.resize(session.cell_session, cols, rows)
      send(session.server, {:ex_ratatui_resize, cols, rows})
    end

    session = %{session | raster: raster}
    if session.frame, do: fresh_frame(session), else: session
  end

  @doc """
  Stops the app server, waiting up to the session's `shutdown_timeout:` for its `terminate/2` before killing it, and closes the cell session. Leaves no `{:EXIT, …}` from the app in the caller's mailbox, even when the app died on its own just before. Safe after `{:exit, _, _}`, when only the cell session is left to close.
  """
  @spec stop(t()) :: :ok
  def stop(%__MODULE__{server: nil} = session), do: CellSession.close(session.cell_session)

  def stop(%__MODULE__{server: server} = session) do
    # Unlinked before the exit this function causes, so that one leaves no
    # EXIT behind. An app that died on its own before the unlink (just
    # before stop/1, or between these two lines) has already sent one; it
    # is flushed below, so the caller's mailbox ends up clean either way.
    ref = Process.monitor(server)
    Process.unlink(server)
    Process.exit(server, :shutdown)

    receive do
      {:DOWN, ^ref, :process, ^server, _reason} -> :ok
    after
      session.shutdown_timeout ->
        Process.exit(server, :kill)

        receive do
          {:DOWN, ^ref, :process, ^server, _reason} -> :ok
        end
    end

    flush_exit(server)

    CellSession.close(session.cell_session)
  end

  @doc "The session's current `RasterExRatatui.Raster`."
  @spec raster(t()) :: Raster.t()
  def raster(%__MODULE__{raster: raster}), do: raster

  @doc "The app server's pid, or `nil` once it has exited."
  @spec server(t()) :: pid() | nil
  def server(%__MODULE__{server: server}), do: server

  @doc "The grid the app renders to, `{cols, rows}`."
  @spec grid_size(t()) :: Raster.size()
  def grid_size(%__MODULE__{raster: raster}), do: Raster.grid_size(raster)

  @doc """
  The whole panel as one row-major buffer of packed pixels: the kept frame with `keep_frame: true`, rendered from the raster otherwise.
  """
  @spec frame(t()) :: binary()
  def frame(%__MODULE__{frame: nil, raster: raster}), do: Raster.frame(raster)
  def frame(%__MODULE__{frame: frame}), do: frame

  defp flush_exit(server) do
    receive do
      {:EXIT, ^server, _reason} -> :ok
    after
      0 -> :ok
    end
  end

  defp new_cell_session(%Raster{} = raster) do
    {cols, rows} = Raster.grid_size(raster)
    CellSession.new(cols, rows, font_size: Raster.font_size(raster))
  end

  defp surface_info(%Raster{} = raster) do
    %{
      size: Raster.size(raster),
      cell_size: Raster.font_size(raster),
      grid_size: Raster.grid_size(raster),
      format: raster.format,
      scale: raster.scale,
      rotate: Raster.rotate(raster)
    }
  end

  defp fresh_frame(%__MODULE__{} = session) do
    {raster, frame} = Raster.render_frame(session.raster)
    %{session | raster: raster, frame: frame}
  end

  defp blit(%__MODULE__{frame: nil}, _patches), do: nil

  defp blit(%__MODULE__{frame: frame, raster: raster}, patches) do
    {width, _height} = Raster.size(raster)
    bpp = Raster.bytes_per_pixel(raster)
    Enum.reduce(patches, frame, &Patch.blit(&2, width, bpp, &1))
  end

  # Every render of this session already in the mailbox, oldest first.
  defp drain_mailbox(ref) do
    receive do
      {__MODULE__, ^ref, %Diff{} = diff} -> [diff | drain_mailbox(ref)]
    after
      0 -> []
    end
  end

  defp current?(%Diff{width: w, height: h}, %__MODULE__{raster: %Raster{grid_size: size}}),
    do: {w, h} == size
end
