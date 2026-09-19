defmodule RasterExRatatui.Framebuffer.Surface do
  @moduledoc """
  A complete surface for a Linux framebuffer and its evdev keyboard, in one `use`.

      defmodule MyDevice.Surface do
        use RasterExRatatui.Framebuffer.Surface, app: MyDevice.Dashboard, rotate: 90
      end

      # in the application's supervision tree
      children = [MyDevice.Surface]

  That is the whole consumer for a Raspberry Pi with a display: at start the surface waits for `/dev/fb0` to appear, reads its size and depth from sysfs, picks the pixel format (`RGB565` at 16 bits per pixel, `XRGB8888` at 32) and a font scale that keeps about a hundred columns on the long side, detaches the kernel console from the framebuffer, starts the app, and reads the first USB keyboard it finds (and the touch panel, with `touch: true`), looking again whenever there is none. Pixels go out with `RasterExRatatui.Framebuffer.write/2`; keys and taps come in through `RasterExRatatui.Input.Devices`. When the app exits, a new one starts on the same surface (`on_app_exit: :restart`), because a panel has nothing else to show.

  ## Options

  Given to `use` or to the child spec (`{MyDevice.Surface, rotate: 90}`), and read from the application's config the usual way. All of `RasterExRatatui.Surface`'s options apply too; these are the ones this module adds or defaults.

  | Option | Default | What it does |
  | ------ | ------- | ------------ |
  | `:app` | required | the `ExRatatui.App` to run |
  | `:framebuffer` | `"fb0"` | the framebuffer to draw on |
  | `:framebuffer_timeout` | `30_000` | how long to wait for it to appear, in milliseconds (display drivers load during boot) |
  | `:scale` | `:auto` | integer font scale, or `:auto` for `RasterExRatatui.Framebuffer.auto_scale/2` |
  | `:columns` | `100` | the columns `:auto` keeps on the long side |
  | `:rotate` | `0` | `90`, `180`, or `270` for a panel mounted on its side (see `RasterExRatatui.Raster`) |
  | `:console` | `"vtcon1"` | the framebuffer console to detach, or `false` to leave it |
  | `:keyboard` | `true` | read the first keyboard found, a `"/dev/input/eventN"` path, or `false` |
  | `:touch` | `false` | the touch panel, the same way: taps and drags reach the app as `ExRatatui.Event.Mouse` events on the cell under the finger, rotation included |
  | `:swap_xy`, `:invert_x`, `:invert_y` | `false` | for a touch controller that does not follow the panel's orientation (`RasterExRatatui.Input.Touch`) |
  | `:on_app_exit` | `:restart` | `:stop` to let the supervisor decide instead; with `:restart`, `:max_restarts` crashes (default 3) within `:max_seconds` (default 5) still stop the surface |
  | `:font`, `:format_opts`, `:app_opts`, `:min_interval`, `:push_mode`, `:shutdown_timeout`, `:name` | | as in `RasterExRatatui.Surface` |
  | `:retry_ms`, `:layout`, `:emit_release`, `:input` | | as in `RasterExRatatui.Input.Devices` |
  | `:root` | `"/"` | where `/sys` and `/dev` are (tests point it at a fake tree) |

  Starting blocks until the framebuffer is there, up to `:framebuffer_timeout`, so the surface belongs last in its supervisor: children after it would wait that long on a slow or missing display.

  The keyboard needs [`input_event`](https://hex.pm/packages/input_event) in the consumer's deps, a C port for Linux. Without it the surface logs a warning once and runs without input, so the same project still compiles and runs its tests on a host.

  ## Under the hood, and overriding

  `use` gives the module `init/1`, `push/2`, `handle_info/2`, and `terminate/2`, each delegating to the function of the same name here, and all overridable. Override one and call the default from it to add to what it does; the state is a map with `:fb` (the open `RasterExRatatui.Framebuffer`) and `:devices` (the `RasterExRatatui.Input.Devices`, or `nil`), and anything else added to it travels along.

      defmodule MyDevice.Surface do
        use RasterExRatatui.Framebuffer.Surface, app: MyDevice.Dashboard

        @impl true
        def init(opts) do
          {:ok, config, state} = RasterExRatatui.Framebuffer.Surface.init(opts)
          {:ok, config, Map.put(state, :backlight, MyDevice.Backlight.on!())}
        end

        @impl true
        def handle_info({:button, :back}, state),
          do: {:events, [%ExRatatui.Event.Key{code: "esc", kind: "press"}], state}

        def handle_info(msg, state), do: RasterExRatatui.Framebuffer.Surface.handle_info(msg, state)
      end

  A panel that is not a framebuffer, or a keyboard that is not evdev, starts from `RasterExRatatui.Surface` instead; [Building a Surface](surfaces.md) is the guide.
  """

  require Logger

  alias RasterExRatatui.Framebuffer
  alias RasterExRatatui.Input.Devices

  @framebuffer_retry_ms 250

  @typedoc "The surface's state: the open framebuffer and the input devices, plus whatever an override adds."
  @type state :: %{
          required(:fb) => Framebuffer.t(),
          required(:devices) => Devices.t() | nil,
          optional(atom()) => term()
        }

  @doc false
  defmacro __using__(opts) do
    quote do
      use RasterExRatatui.Surface, unquote(opts)

      @impl RasterExRatatui.Surface
      def init(opts), do: RasterExRatatui.Framebuffer.Surface.init(opts)

      @impl RasterExRatatui.Surface
      def push(pixels, state), do: RasterExRatatui.Framebuffer.Surface.push(pixels, state)

      @impl RasterExRatatui.Surface
      def handle_info(msg, state), do: RasterExRatatui.Framebuffer.Surface.handle_info(msg, state)

      @impl RasterExRatatui.Surface
      def terminate(reason, state),
        do: RasterExRatatui.Framebuffer.Surface.terminate(reason, state)

      defoverridable init: 1, push: 2, handle_info: 2, terminate: 2
    end
  end

  @doc """
  The default `c:RasterExRatatui.Surface.init/1`: waits for the framebuffer, picks the format and scale, detaches the console, starts the input devices.

  Returns `{:ok, [size:, format:, scale:, rotate:, on_app_exit:], %{fb:, devices:}}`, or `{:stop, {:framebuffer, reason}}` when the framebuffer never appears or has a depth the library cannot pack (that one fails at once).
  """
  @spec init(keyword()) :: {:ok, keyword(), state()} | {:stop, {:framebuffer, term()}}
  def init(opts) do
    root_opts = Keyword.take(opts, [:root])
    name = Keyword.get(opts, :framebuffer, "fb0")
    timeout = Keyword.get(opts, :framebuffer_timeout, 30_000)

    with {:ok, fb} <- open(name, root_opts, timeout, timeout),
         {:ok, format} <- Framebuffer.format_for(fb.info) do
      size = {fb.info.width, fb.info.height}
      scale = scale(opts, size)
      console = Keyword.get(opts, :console, "vtcon1")
      unbound = if console, do: Framebuffer.unbind_console(console, root_opts), else: :skipped

      Logger.info(
        "#{inspect(__MODULE__)}: #{name} #{inspect(fb.info)} as #{inspect(format)} at scale #{scale}, console unbind: #{inspect(unbound)}"
      )

      config = [
        size: size,
        format: format,
        scale: scale,
        rotate: Keyword.get(opts, :rotate, 0),
        on_app_exit: Keyword.get(opts, :on_app_exit, :restart)
      ]

      {:ok, config, %{fb: fb, devices: devices(opts, config)}}
    else
      {:error, reason} -> {:stop, {:framebuffer, reason}}
    end
  end

  @doc """
  The default `c:RasterExRatatui.Surface.push/2`: `RasterExRatatui.Framebuffer.write/2`.
  """
  @spec push([RasterExRatatui.Patch.t()] | {:frame, binary()}, state()) :: state()
  def push(pixels, %{fb: fb} = state) do
    :ok = Framebuffer.write(fb, pixels)
    state
  end

  @doc """
  The default `c:RasterExRatatui.Surface.handle_info/2`: `RasterExRatatui.Input.Devices.handle_info/2`, with anything it does not know ignored.
  """
  @spec handle_info(term(), state()) ::
          {:noreply, state()} | {:events, [ExRatatui.Event.t()], state()}
  def handle_info(_msg, %{devices: nil} = state), do: {:noreply, state}

  def handle_info(msg, %{devices: devices} = state) do
    case Devices.handle_info(msg, devices) do
      {:events, events, devices} -> {:events, events, %{state | devices: devices}}
      {:noreply, devices} -> {:noreply, %{state | devices: devices}}
      :unknown -> {:noreply, state}
    end
  end

  @doc """
  The default `c:RasterExRatatui.Surface.terminate/2`: stops the input readers and closes the framebuffer.
  """
  @spec terminate(term(), state()) :: :ok | {:error, term()}
  def terminate(_reason, %{fb: fb, devices: devices} = _state) do
    if devices, do: Devices.stop(devices)
    Framebuffer.close(fb)
  end

  # Only a missing device is worth waiting for; a depth the library cannot
  # pack will not get better. Logs on the first look and every five seconds.
  defp open(name, root_opts, remaining, timeout) do
    case Framebuffer.open(name, root_opts) do
      {:ok, fb} ->
        {:ok, fb}

      {:error, _reason} when remaining > 0 ->
        if remaining == timeout or rem(remaining, 5_000) == 0 do
          Logger.info("#{inspect(__MODULE__)}: waiting for #{name}")
        end

        Process.sleep(@framebuffer_retry_ms)
        open(name, root_opts, remaining - @framebuffer_retry_ms, timeout)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp scale(opts, size) do
    case Keyword.get(opts, :scale, :auto) do
      :auto -> Framebuffer.auto_scale(size, Keyword.take(opts, [:font, :columns]))
      scale -> scale
    end
  end

  defp devices(opts, config) do
    devices =
      opts
      |> Keyword.take([:input, :keyboard, :touch, :retry_ms, :layout, :emit_release])
      |> Keyword.merge(touch_opts(opts, config))
      |> Devices.new()

    case Devices.start(devices) do
      {:ok, devices} ->
        devices

      {:error, :input_event_missing} ->
        Logger.warning(
          "#{inspect(__MODULE__)}: input_event is not available, running without input (add {:input_event, \"~> 1.4\"} to the deps)"
        )

        nil
    end
  end

  # The touch panel reports pixels; the cell under a finger is the raster's
  # to say, so a raster of the same geometry as the surface's (it is built
  # from the same config) answers `cell_at`, rotation included. Only built
  # when there is a touch panel to read.
  defp touch_opts(opts, config) do
    if Keyword.get(opts, :touch, false) do
      raster =
        config
        |> Keyword.take([:size, :format, :scale, :rotate])
        |> Keyword.merge(Keyword.take(opts, [:font, :format_opts]))
        |> RasterExRatatui.Raster.new()

      Keyword.take(opts, [:swap_xy, :invert_x, :invert_y]) ++
        [
          size: Keyword.fetch!(config, :size),
          cell_at: &RasterExRatatui.Raster.cell_at(raster, &1)
        ]
    else
      []
    end
  end
end
