defmodule RasterExRatatui.Surface do
  @moduledoc """
  The contract a pixel display implements to run an ExRatatui app.

  A surface is a module that knows one panel: how big it is, how its pixels are packed, and how to get bytes onto it. Everything between the app and those bytes (starting the app, folding cell diffs, rasterising glyphs and pixel regions, forwarding input) is done by the surface process that `use RasterExRatatui.Surface` gives the module.

      defmodule MyDevice.Surface do
        use RasterExRatatui.Surface,
          app: MyDevice.Dashboard,
          format: RasterExRatatui.PixelFormat.RGB565,
          scale: 2

        @impl true
        def init(opts) do
          lcd = MyDevice.LCD.open!()
          {:ok, [size: MyDevice.LCD.size(lcd)], lcd}
        end

        @impl true
        def push(patches, lcd) do
          Enum.each(patches, &MyDevice.LCD.write(lcd, &1.x, &1.y, &1.width, &1.height, &1.data))
          lcd
        end
      end

      # in the application's supervision tree
      children = [MyDevice.Surface]

  ## Lifecycle

  1. `start_link/1` merges its options over the `use` options and calls `c:init/1` with the result.
  2. `c:init/1` returns the consumer's state and a keyword list of options it could only know at runtime (typically `:size`, read from the device); those win over everything else.
  3. The process builds a `RasterExRatatui.Raster` and starts a `RasterExRatatui.Session` on it, which creates an `ExRatatui.CellSession` of the raster's grid with the raster's `font_size:` and starts the app server on it, linked.
  4. Every render of the app arrives as a cell diff; the raster turns it into patches and `c:push/2` writes them.
  5. When the app server exits, `:on_app_exit` decides. With `:stop`, the default, the surface exits with the same reason; the generated child spec is `restart: :transient`, like `ExRatatui.App`'s, so a crash restarts the pair and an app that quits with `{:stop, state}` stays stopped. With `:restart`, the surface keeps its raster, opens a fresh cell session, and starts the app again; the new app's first render repaints the panel. When the surface stops, it stops the app server first.

  ## Options

  Accepted by `use`, by `start_link/1`, and in the keyword list `c:init/1` returns (later wins, in that order):

    * `:app` (required) — the `ExRatatui.App` module to run
    * `:app_opts` — keyword list passed to the app's `mount/1` (or reducer `init/1`), default `[]`. The surface adds `surface:` to it, a map describing the panel the app is on: `:size` (the physical panel in pixels), `:cell_size` (the effective cell in pixels), `:grid_size` (cells), `:format`, `:scale`, and `:rotate`
    * `:size` (required) — the physical panel size in pixels, `{width, height}`
    * `:format` (required) — a `RasterExRatatui.PixelFormat` module
    * `:rotate` — `0` (default), `90`, `180`, or `270`: how far clockwise the app's image is turned on the panel, for a panel mounted on its side. The grid follows the turned image; patches and frames stay in the panel's own coordinates, so `c:push/2` does not change
    * `:font`, `:scale`, `:format_opts` — see `RasterExRatatui.Raster.new/1`
    * `:push_mode` — `:patches` (default) calls `c:push/2` with the changed rectangles; `:frame` calls it with `{:frame, binary}`, the whole panel, for panels that only take full frames
    * `:min_interval` — minimum milliseconds between two pushes (default `0`). Renders arriving sooner wait, and are rasterised together and pushed once when the interval has passed, which keeps slow panels (e-ink, SPI at low baud) from refreshing more often than they should
    * `:on_app_exit` — what to do when the app server exits: `:stop` (default) stops the surface with the same reason, and its supervisor decides; `:restart` starts the app again on the same surface at once, for a panel that has nothing else to show. Both emit `[:raster_ex_ratatui, :app, :exit]` with the reason and the action
    * `:shutdown_timeout` — milliseconds to wait for the app server to stop when the surface terminates before killing it (default `4_000`), so the consumer's `c:terminate/2` still runs within a supervisor's default 5-second shutdown
    * `:name` — registers the surface process

  Every other option reaches `c:init/1` untouched, so device settings (a device path, a GPIO pin) can travel with the rest.

  The surface never falls behind the app. Every render that is waiting when the surface gets to work is folded into the raster as one batch (`RasterExRatatui.Raster.apply/2` with a list) and pushed at once, so when the app renders faster than the surface can rasterise or the panel can write, the panel shows fewer, later frames rather than every frame later and later, and input never waits behind stale renders. A `min_interval` holds the batch back instead.

  ## Input

  Input belongs to the consumer: whatever reads the device (an evdev keyboard, GPIO buttons, a touch controller) turns its events into `ExRatatui.Event` structs and hands them to `send_event/2`. When the reader delivers messages to the surface process itself, `c:handle_info/2` can translate them and return `{:events, events, state}`. `RasterExRatatui.Input.Evdev` translates evdev key events.

  ## Resize

  `resize/2` changes the panel size (a display that comes back at another resolution): the raster and the session are rebuilt at the new grid, the app receives an `ExRatatui.Event.Resize`, and the next render repaints the whole panel.
  """

  alias RasterExRatatui.{Patch, Raster}

  @typedoc "A running surface: its pid or registered name."
  @type surface :: GenServer.server()

  @doc """
  Prepares the device and returns the consumer's state.

  `opts` is every option given to `use` and `start_link/1`, merged. The returned keyword list is merged over them, so options only known once the device is open (`:size`, `:format`) are returned here. Returning `{:stop, reason}` aborts the start; any other return raises `ArgumentError`.

  The default implementation returns `{:ok, [], opts}`: no extra options, and the options themselves as state.
  """
  @callback init(opts :: keyword()) ::
              {:ok, keyword(), state :: term()} | {:stop, reason :: term()}

  @doc """
  Writes pixels to the device and returns the new state.

  Receives the list of `RasterExRatatui.Patch` rectangles to write in order (`push_mode: :patches`), or `{:frame, binary}` with the whole panel, row-major, `width * height` packed pixels (`push_mode: :frame`). Called from the surface process; a slow push delays the next one but never the app.
  """
  @callback push(pixels :: [Patch.t()] | {:frame, binary()}, state :: term()) :: term()

  @doc """
  Handles any other message sent to the surface process.

  Return `{:events, events, state}` to forward `ExRatatui.Event` structs to the app, or `{:noreply, state}`. The default ignores the message.
  """
  @callback handle_info(msg :: term(), state :: term()) ::
              {:noreply, term()} | {:events, [ExRatatui.Event.t()], term()}

  @doc """
  Called when the surface stops, after the app server is stopped. The default does nothing.
  """
  @callback terminate(reason :: term(), state :: term()) :: term()

  @doc false
  defmacro __using__(use_opts) do
    quote location: :keep do
      @behaviour RasterExRatatui.Surface

      @doc false
      def child_spec(opts) do
        %{
          id: __MODULE__,
          start: {__MODULE__, :start_link, [opts]},
          type: :worker,
          restart: :transient
        }
      end

      @doc false
      def start_link(opts \\ []) when is_list(opts) do
        RasterExRatatui.Surface.start_link(__MODULE__, Keyword.merge(unquote(use_opts), opts))
      end

      @impl RasterExRatatui.Surface
      def init(opts), do: {:ok, [], opts}

      @impl RasterExRatatui.Surface
      def handle_info(_msg, state), do: {:noreply, state}

      @impl RasterExRatatui.Surface
      def terminate(_reason, _state), do: :ok

      defoverridable child_spec: 1, init: 1, handle_info: 2, terminate: 2
    end
  end

  @doc """
  Starts the surface process for `module`, a module implementing this behaviour, with `opts` (see the moduledoc). Modules that `use RasterExRatatui.Surface` get a `start_link/1` that calls this with their `use` options merged in.
  """
  @spec start_link(module(), keyword()) :: GenServer.on_start()
  def start_link(module, opts) when is_atom(module) and is_list(opts) do
    case Keyword.pop(opts, :name) do
      {nil, opts} -> GenServer.start_link(__MODULE__.Server, {module, opts})
      {name, opts} -> GenServer.start_link(__MODULE__.Server, {module, opts}, name: name)
    end
  end

  @doc """
  Forwards an `ExRatatui.Event` (a `%Key{}`, a `%Mouse{}`, …) to the app.

  Returns immediately; the event reaches the app's `handle_event/2` (or `update/2`) like input from a terminal.
  """
  @spec send_event(surface(), ExRatatui.Event.t()) :: :ok
  def send_event(surface, event), do: GenServer.cast(surface, {:event, event})

  @doc """
  Changes the panel size. The grid, the session, and the app are resized, and the next render repaints the panel.

  Returns the new grid size, `{cols, rows}`.
  """
  @spec resize(surface(), Raster.size()) :: Raster.size()
  def resize(surface, {width, height} = size) when is_integer(width) and is_integer(height) do
    GenServer.call(surface, {:resize, size})
  end

  @doc """
  The pid of the app server the surface runs.
  """
  @spec server(surface()) :: pid()
  def server(surface), do: GenServer.call(surface, :server)

  @doc """
  The surface's current `RasterExRatatui.Raster`, for inspection and tests (`RasterExRatatui.Raster.frame/1` renders what the panel shows).
  """
  @spec raster(surface()) :: Raster.t()
  def raster(surface), do: GenServer.call(surface, :raster)
end
