defmodule RpiFramebuffer.Surface do
  @moduledoc """
  The panel as a `RasterExRatatui.Surface`: `/dev/fb0` for pixels, the first USB keyboard for input.

  Nothing about the panel is configured. At startup the surface reads the framebuffer's geometry from sysfs, picks the pixel format from its depth (the KMS fbdev emulation gives the DSI Touch Display 2 16 bits per pixel and most HDMI monitors 32), and derives the font scale from the size (`default_scale/1`). It then detaches the kernel's framebuffer console so no cursor blinks over the app, and looks for a keyboard.

  The display drivers are kernel modules that load while the system boots, so `/dev/fb0` can show up seconds after the application starts. `init/1` waits for it (`:framebuffer_timeout`) instead of failing on the first look.

  A keyboard that is missing at boot, or unplugged later, is looked for again every two seconds. Its reader grabs the device, so keys reach the dashboard and nothing else, and the surface stops the reader when it stops itself: a linked process does not follow a normal exit (the dashboard quitting on `ctrl+q`), and a reader left behind keeps the grab, so the next surface's reader is disconnected at once.

  Patches go to the device as they come: `push/2` is one positioned write per patch row, in a single `:file.pwrite/2`.

  ## Options

  Read from `config :rpi_framebuffer, RpiFramebuffer.Surface` on the device:

    * `:scale` — integer font scale, default `default_scale/1` of the panel size
    * `:framebuffer` — the framebuffer name, default `"fb0"`
    * `:framebuffer_timeout` — how long to wait for the framebuffer to appear, in milliseconds, default `30_000`
    * `:console` — the framebuffer console to unbind, default `"vtcon1"`
    * `:keyboard` — whether to look for a keyboard, default `true`
    * `:spin_ms` — passed to the dashboard, see `RpiFramebuffer.Dashboard.Showcase`
    * `:root` — filesystem root for `/sys`, `/dev`, and the dashboard's `/proc`, default `"/"` (tests point it at a fake tree)
    * `:input` — the module that finds and reads input devices, default `InputEvent` (tests pass a stub)
  """

  use RasterExRatatui.Surface, app: RpiFramebuffer.Dashboard

  require Logger

  alias RasterExRatatui.Framebuffer
  alias RasterExRatatui.Input.Evdev

  @keyboard_retry_ms 2_000
  @framebuffer_timeout_ms 30_000
  @framebuffer_retry_ms 250

  # The library font's cell width, and the fewest columns the long side of
  # the panel should keep.
  @cell_width 6
  @columns 100

  @impl true
  def init(opts) do
    fs_opts = Keyword.take(opts, [:root])

    name = Keyword.get(opts, :framebuffer, "fb0")
    timeout = Keyword.get(opts, :framebuffer_timeout, @framebuffer_timeout_ms)

    with {:ok, fb} <- open_framebuffer(name, fs_opts, timeout),
         {:ok, format} <- Framebuffer.format_for(fb.info) do
      size = {fb.info.width, fb.info.height}
      scale = Keyword.get(opts, :scale) || default_scale(size)
      unbound = Framebuffer.unbind_console(Keyword.get(opts, :console, "vtcon1"), fs_opts)

      Logger.info(
        "RpiFramebuffer.Surface: #{inspect(fb.info)} as #{inspect(format)} at scale #{scale}, console unbind: #{inspect(unbound)}"
      )

      if Keyword.get(opts, :keyboard, true), do: send(self(), :find_keyboard)

      config = [
        size: size,
        format: format,
        scale: scale,
        app_opts: Keyword.take(opts, [:root, :spin_ms])
      ]

      state = %{
        fb: fb,
        input: Keyword.get(opts, :input, InputEvent),
        keyboard: Evdev.new(),
        reader: nil
      }

      {:ok, config, state}
    else
      {:error, reason} -> {:stop, {:framebuffer, reason}}
    end
  end

  # Only a missing device is worth waiting for; a depth the library cannot
  # pack will not get better.
  defp open_framebuffer(name, fs_opts, remaining) do
    case Framebuffer.open(name, fs_opts) do
      {:ok, fb} ->
        {:ok, fb}

      {:error, _reason} when remaining > 0 ->
        if remaining == @framebuffer_timeout_ms or rem(remaining, 5_000) == 0 do
          Logger.info("RpiFramebuffer.Surface: waiting for #{name}")
        end

        Process.sleep(@framebuffer_retry_ms)
        open_framebuffer(name, fs_opts, remaining - @framebuffer_retry_ms)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def push(pixels, state) do
    :ok = Framebuffer.write(state.fb, pixels)
    state
  end

  @impl true
  # The reader says :disconnect when its keyboard goes away or another reader
  # holds the grab, then exits; the EXIT below starts the search again.
  def handle_info({:input_event, path, :disconnect}, state) do
    Logger.info("RpiFramebuffer.Surface: the keyboard at #{path} went away")
    {keyboard, []} = Evdev.translate_all(state.keyboard, :disconnect)
    {:noreply, %{state | keyboard: keyboard}}
  end

  def handle_info({:input_event, _path, events}, state) do
    {keyboard, keys} = Evdev.translate_all(state.keyboard, events)
    {:events, keys, %{state | keyboard: keyboard}}
  end

  def handle_info(:find_keyboard, %{reader: nil} = state) do
    case keyboard_path(state.input.enumerate()) do
      nil ->
        Process.send_after(self(), :find_keyboard, @keyboard_retry_ms)
        {:noreply, state}

      path ->
        {:ok, reader} = state.input.start_link(path: path, grab: true)
        Logger.info("RpiFramebuffer.Surface: reading the keyboard at #{path}")
        # A fresh translator: modifiers held when the old keyboard went away are gone with it.
        {:noreply, %{state | reader: reader, keyboard: Evdev.new()}}
    end
  end

  # The reader stops when its keyboard is unplugged; look for one again.
  def handle_info({:EXIT, reader, _reason}, %{reader: reader} = state) when is_pid(reader) do
    send(self(), :find_keyboard)
    {:noreply, %{state | reader: nil}}
  end

  # Everything else, including the exits of the short-lived readers that
  # enumerating input devices starts and stops.
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if is_pid(state.reader) and Process.alive?(state.reader), do: state.input.stop(state.reader)
    Framebuffer.close(state.fb)
  end

  @doc """
  The largest integer font scale that keeps at least #{@columns} columns of the 6-pixel-wide library font on the panel's long side, and never less than 1.

  ## Examples

  The Touch Display 2, 720×1280, gets 12×16 pixel cells: 60×80 in portrait, 106×45 once rotated.

      iex> RpiFramebuffer.Surface.default_scale({720, 1280})
      2

  A 1080p monitor gets 18×24 pixel cells, 106×45:

      iex> RpiFramebuffer.Surface.default_scale({1920, 1080})
      3

      iex> RpiFramebuffer.Surface.default_scale({3840, 2160})
      6

      iex> RpiFramebuffer.Surface.default_scale({480, 320})
      1
  """
  @spec default_scale({pos_integer(), pos_integer()}) :: pos_integer()
  def default_scale({width, height}) do
    max(div(max(width, height), @columns * @cell_width), 1)
  end

  @doc """
  The path of the first device in an `InputEvent.enumerate/0` list that reports letter keys, or `nil`. Mice, touch panels, and power buttons report `:ev_key` too, but not `:key_a`.

  ## Examples

      iex> RpiFramebuffer.Surface.keyboard_path([
      ...>   {"/dev/input/event0", %{report_info: [ev_key: [:btn_touch], ev_abs: [abs_x: %{}]]}},
      ...>   {"/dev/input/event1", %{report_info: [ev_key: [:key_esc, :key_a, :key_b], ev_led: [:led_capsl]]}}
      ...> ])
      "/dev/input/event1"

      iex> RpiFramebuffer.Surface.keyboard_path([])
      nil
  """
  @spec keyboard_path([{String.t(), %{report_info: [{atom(), [term()]}]}}]) :: String.t() | nil
  def keyboard_path(devices) do
    Enum.find_value(devices, fn {path, info} ->
      if Enum.any?(info.report_info, &letter_keys?/1), do: path
    end)
  end

  defp letter_keys?({:ev_key, codes}), do: :key_a in codes
  defp letter_keys?(_report), do: false
end
