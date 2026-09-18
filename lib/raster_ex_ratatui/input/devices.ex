defmodule RasterExRatatui.Input.Devices do
  @moduledoc """
  Finds and reads the evdev input devices a panel comes with, and finds them again when they go away.

  A keyboard on a Nerves device is `/dev/input/eventN` for some N that changes with what else is plugged in, may not exist at boot, and goes away when unplugged. This module owns that: which device to read, starting an `input_event` reader on it with the device grabbed (so keystrokes do not also reach the kernel console), translating what it delivers into `ExRatatui.Event` structs, and looking again, every `retry_ms:`, whenever there is nothing to read. It has no process of its own: the caller keeps the struct, hands it every message it receives, and gets events back, from a surface's `c:RasterExRatatui.Surface.handle_info/2` or from any process that traps exits.

      defmodule Kiosk.Surface do
        use RasterExRatatui.Surface, app: Kiosk.Dashboard, format: RasterExRatatui.PixelFormat.RGB565

        alias RasterExRatatui.Input.Devices

        @impl true
        def init(_opts) do
          {:ok, devices} = Devices.start(Devices.new(keyboard: true))
          {:ok, [size: {480, 320}], devices}
        end

        @impl true
        def push(patches, devices), do: write(patches) && devices

        @impl true
        def handle_info(msg, devices) do
          case Devices.handle_info(msg, devices) do
            {:events, keys, devices} -> {:events, keys, devices}
            {:noreply, devices} -> {:noreply, devices}
            :unknown -> {:noreply, devices}
          end
        end

        @impl true
        def terminate(_reason, devices), do: Devices.stop(devices)
      end

  ## `input_event` is the consumer's dependency

  The reader is [`input_event`](https://hex.pm/packages/input_event), a C port that only builds on Linux, so this library does not depend on it: the consumer adds `{:input_event, "~> 1.4"}` to its own deps. `start/1` checks that the module is there and returns `{:error, :input_event_missing}` otherwise, so a host build without it still runs, without input. `input:` swaps the module for a stub in tests.

  ## Options

  `new/1` takes:

    * `:keyboard` — `true` (default) to read the first device that reports letter keys, a `"/dev/input/eventN"` path to read that one, or `false`
    * `:touch` — `true`, a path, or `false` (default). Accepted now, read from the next release on
    * `:retry_ms` — how long to wait before looking for a missing device again (default `2_000`)
    * `:input` — the module standing in for `InputEvent` (default `InputEvent`)
    * `:layout`, `:emit_release` — passed to `RasterExRatatui.Input.Evdev.new/1`

  ## Messages

  `start/1` sends the calling process a first `{RasterExRatatui.Input.Devices, :scan}`; `handle_info/2` handles it and every later one, the `{:input_event, path, events}` and `{:input_event, path, :disconnect}` messages of the readers it started, and their `{:EXIT, pid, reason}` (a reader stops when its device goes away, and the search starts over). Everything else is `:unknown`, including the `:normal` exits of the short-lived readers that `InputEvent.enumerate/0` starts from the caller while scanning.
  """

  require Logger

  alias RasterExRatatui.Input.Evdev

  @type device :: {path :: String.t(), %{report_info: [{atom(), [term()]}]}}

  @type t :: %__MODULE__{
          input: module(),
          keyboard: boolean() | String.t(),
          touch: boolean() | String.t(),
          retry_ms: non_neg_integer(),
          evdev_opts: keyword(),
          keyboard_path: String.t() | nil,
          keyboard_reader: pid() | nil,
          evdev: Evdev.t(),
          timer: reference() | nil
        }

  defstruct input: InputEvent,
            keyboard: true,
            touch: false,
            retry_ms: 2_000,
            evdev_opts: [],
            keyboard_path: nil,
            keyboard_reader: nil,
            evdev: nil,
            timer: nil

  @doc """
  Builds the state from the options in the moduledoc. Raises `ArgumentError` on a bad option.

  ## Examples

      iex> devices = RasterExRatatui.Input.Devices.new(keyboard: "/dev/input/event3", retry_ms: 500)
      iex> {devices.keyboard, devices.retry_ms, RasterExRatatui.Input.Devices.keyboard(devices)}
      {"/dev/input/event3", 500, nil}
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) when is_list(opts) do
    keyboard = Keyword.get(opts, :keyboard, true)
    touch = Keyword.get(opts, :touch, false)
    retry_ms = Keyword.get(opts, :retry_ms, 2_000)
    input = Keyword.get(opts, :input, InputEvent)

    validate!(:keyboard, keyboard, is_boolean(keyboard) or is_binary(keyboard))
    validate!(:touch, touch, is_boolean(touch) or is_binary(touch))
    validate!(:retry_ms, retry_ms, is_integer(retry_ms) and retry_ms >= 0)
    validate!(:input, input, is_atom(input) and not is_nil(input))

    evdev_opts = Keyword.take(opts, [:layout, :emit_release])

    %__MODULE__{
      input: input,
      keyboard: keyboard,
      touch: touch,
      retry_ms: retry_ms,
      evdev_opts: evdev_opts,
      evdev: Evdev.new(evdev_opts)
    }
  end

  @doc """
  Starts looking for the devices: the first scan arrives as a message to the calling process, which must trap exits (the readers are linked).

  Returns `{:ok, devices}`, or `{:error, :input_event_missing}` when a device is wanted and the `input:` module is not available.
  """
  @spec start(t()) :: {:ok, t()} | {:error, :input_event_missing}
  def start(%__MODULE__{} = devices) do
    cond do
      devices.keyboard == false and devices.touch == false -> {:ok, devices}
      not Code.ensure_loaded?(devices.input) -> {:error, :input_event_missing}
      true -> {:ok, scan_soon(devices, 0)}
    end
  end

  @doc """
  Handles a message from the calling process's mailbox.

  Returns `{:events, events, devices}` with the `ExRatatui.Event` structs a reader's message translated to, `{:noreply, devices}` for the other messages of this module, or `:unknown`.
  """
  @spec handle_info(term(), t()) ::
          {:events, [ExRatatui.Event.t()], t()} | {:noreply, t()} | :unknown
  def handle_info({__MODULE__, :scan}, %__MODULE__{} = devices) do
    {:noreply, scan(%{devices | timer: nil})}
  end

  def handle_info({:input_event, path, :disconnect}, %__MODULE__{keyboard_path: path} = devices)
      when is_binary(path) do
    Logger.info("#{inspect(__MODULE__)}: the keyboard at #{path} went away")
    {evdev, []} = Evdev.translate_all(devices.evdev, :disconnect)
    {:noreply, %{devices | evdev: evdev}}
  end

  def handle_info({:input_event, path, events}, %__MODULE__{keyboard_path: path} = devices)
      when is_binary(path) and is_list(events) do
    {evdev, keys} = Evdev.translate_all(devices.evdev, events)
    {:events, keys, %{devices | evdev: evdev}}
  end

  # The reader stops when its device is unplugged; look for one again.
  def handle_info({:EXIT, reader, _reason}, %__MODULE__{keyboard_reader: reader} = devices)
      when is_pid(reader) do
    {:noreply, scan(%{devices | keyboard_reader: nil, keyboard_path: nil})}
  end

  def handle_info(_msg, %__MODULE__{}), do: :unknown

  @doc """
  Stops the readers that are running and any pending scan. Returns the devices, idle; `start/1` starts them again.
  """
  @spec stop(t()) :: t()
  def stop(%__MODULE__{} = devices) do
    if devices.timer, do: Process.cancel_timer(devices.timer)

    if is_pid(devices.keyboard_reader) and Process.alive?(devices.keyboard_reader),
      do: devices.input.stop(devices.keyboard_reader)

    %{devices | keyboard_reader: nil, keyboard_path: nil, timer: nil}
  end

  @doc "The path of the keyboard being read, or `nil` while there is none."
  @spec keyboard(t()) :: String.t() | nil
  def keyboard(%__MODULE__{keyboard_path: path}), do: path

  @doc """
  The path of the first device in an `InputEvent.enumerate/0` list that reports letter keys, or `nil`. Mice, touch panels, and power buttons report `:ev_key` too, but not `:key_a`.

  ## Examples

      iex> RasterExRatatui.Input.Devices.keyboard_path([
      ...>   {"/dev/input/event0", %{report_info: [ev_key: [:btn_touch], ev_abs: [abs_x: %{}]]}},
      ...>   {"/dev/input/event1", %{report_info: [ev_key: [:key_esc, :key_a, :key_b], ev_led: [:led_capsl]]}}
      ...> ])
      "/dev/input/event1"

      iex> RasterExRatatui.Input.Devices.keyboard_path([])
      nil
  """
  @spec keyboard_path([device()]) :: String.t() | nil
  def keyboard_path(devices) do
    Enum.find_value(devices, fn {path, info} ->
      if Enum.any?(info.report_info, &letter_keys?/1), do: path
    end)
  end

  @doc """
  The path of the first device in an `InputEvent.enumerate/0` list that is a touch panel: one reporting the multitouch `:abs_mt_position_x` axis, or else `:abs_x` together with `:btn_touch`. `nil` when there is none.

  ## Examples

      iex> RasterExRatatui.Input.Devices.touch_path([
      ...>   {"/dev/input/event1", %{report_info: [ev_key: [:key_a]]}},
      ...>   {"/dev/input/event2", %{report_info: [ev_key: [:btn_left], ev_abs: [abs_x: %{}, abs_y: %{}]]}},
      ...>   {"/dev/input/event3", %{report_info: [ev_key: [:btn_touch], ev_abs: [abs_x: %{}, abs_y: %{}, abs_mt_position_x: %{}]]}}
      ...> ])
      "/dev/input/event3"

      iex> RasterExRatatui.Input.Devices.touch_path([
      ...>   {"/dev/input/event4", %{report_info: [ev_key: [:btn_touch], ev_abs: [abs_x: %{}, abs_y: %{}]]}}
      ...> ])
      "/dev/input/event4"

      iex> RasterExRatatui.Input.Devices.touch_path([])
      nil
  """
  @spec touch_path([device()]) :: String.t() | nil
  def touch_path(devices) do
    Enum.find_value(devices, fn {path, info} -> if touch?(info.report_info), do: path end)
  end

  @doc """
  The ranges of a touch panel's axes, `%{x: {min, max}, y: {min, max}}`, from a device's `report_info` (the multitouch axes when present, else the single-touch ones), or `nil` when the device has no such axes.

  ## Examples

      iex> RasterExRatatui.Input.Devices.touch_axes(%{
      ...>   report_info: [
      ...>     ev_key: [:btn_touch],
      ...>     ev_abs: [
      ...>       abs_x: %{min: 0, max: 719},
      ...>       abs_y: %{min: 0, max: 1279},
      ...>       abs_mt_position_x: %{min: 0, max: 719},
      ...>       abs_mt_position_y: %{min: 0, max: 1279}
      ...>     ]
      ...>   ]
      ...> })
      %{x: {0, 719}, y: {0, 1279}}

      iex> RasterExRatatui.Input.Devices.touch_axes(%{report_info: [ev_key: [:key_a]]})
      nil
  """
  @spec touch_axes(%{report_info: [{atom(), [term()]}]}) ::
          %{x: {integer(), integer()}, y: {integer(), integer()}} | nil
  def touch_axes(%{report_info: report_info}) do
    axes = Keyword.get(report_info, :ev_abs, [])

    with {x, y} when x != nil and y != nil <-
           axis_pair(axes, :abs_mt_position_x, :abs_mt_position_y),
         %{min: x_min, max: x_max} <- x,
         %{min: y_min, max: y_max} <- y do
      %{x: {x_min, x_max}, y: {y_min, y_max}}
    else
      _missing -> nil
    end
  end

  defp axis_pair(axes, x_code, y_code) do
    case {Keyword.get(axes, x_code), Keyword.get(axes, y_code)} do
      {nil, _} when x_code == :abs_mt_position_x -> axis_pair(axes, :abs_x, :abs_y)
      pair -> pair
    end
  end

  # -- scanning --------------------------------------------------------------

  defp scan(%__MODULE__{keyboard: false} = devices), do: devices
  defp scan(%__MODULE__{keyboard_reader: pid} = devices) when is_pid(pid), do: devices

  defp scan(%__MODULE__{} = devices) do
    case keyboard_candidate(devices) do
      nil ->
        scan_soon(devices, devices.retry_ms)

      path ->
        case devices.input.start_link(path: path, grab: true) do
          {:ok, reader} ->
            Logger.info("#{inspect(__MODULE__)}: reading the keyboard at #{path}")
            # A fresh translator: modifiers held on the old keyboard are gone with it.
            %{
              devices
              | keyboard_reader: reader,
                keyboard_path: path,
                evdev: Evdev.new(devices.evdev_opts)
            }

          {:error, reason} ->
            Logger.warning("#{inspect(__MODULE__)}: cannot read #{path}: #{inspect(reason)}")
            scan_soon(devices, devices.retry_ms)
        end
    end
  end

  defp keyboard_candidate(%__MODULE__{keyboard: true} = devices),
    do: keyboard_path(devices.input.enumerate())

  defp keyboard_candidate(%__MODULE__{keyboard: path}) when is_binary(path), do: path

  # At most one scan on its way.
  defp scan_soon(%__MODULE__{timer: nil} = devices, delay),
    do: %{devices | timer: Process.send_after(self(), {__MODULE__, :scan}, delay)}

  defp scan_soon(%__MODULE__{} = devices, _delay), do: devices

  defp letter_keys?({:ev_key, codes}), do: :key_a in codes
  defp letter_keys?(_report), do: false

  defp touch?(report_info) do
    axes = Keyword.get(report_info, :ev_abs, [])
    keys = Keyword.get(report_info, :ev_key, [])

    Keyword.has_key?(axes, :abs_mt_position_x) or
      (Keyword.has_key?(axes, :abs_x) and :btn_touch in keys)
  end

  defp validate!(_key, _value, true), do: :ok

  defp validate!(key, value, false),
    do:
      raise(
        ArgumentError,
        "invalid #{inspect(key)} for #{inspect(__MODULE__)}: #{inspect(value)}"
      )
end
