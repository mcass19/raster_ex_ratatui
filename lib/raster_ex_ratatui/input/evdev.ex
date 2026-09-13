defmodule RasterExRatatui.Input.Evdev do
  @moduledoc """
  Translates Linux evdev keyboard events into `ExRatatui.Event.Key` structs.

  A terminal hands an app finished key events: `"A"` with `["shift"]`, `"back_tab"`, `"c"` with `["ctrl"]`. A USB keyboard read through evdev (with the [`input_event`](https://hex.pm/packages/input_event) library, for instance) only reports physical keys going down, repeating, and coming up, so something has to remember which modifiers are held and which character a key makes. This module is that something: pure, no process, no dependency on `input_event`.

  It consumes the `{type, code, value}` tuples `input_event` delivers in `{:input_event, path, events}` messages and keeps only `:ev_key` ones:

      {:ok, _pid} = InputEvent.start_link(path: "/dev/input/event0", grab: true)
      keyboard = Evdev.new()

      # in the process receiving the messages (a surface's handle_info/2):
      def handle_info({:input_event, _path, events}, %{keyboard: keyboard} = state) do
        {keyboard, keys} = Evdev.translate_all(keyboard, events)
        {:events, keys, %{state | keyboard: keyboard}}
      end

  Keys come out the way crossterm reports them in a terminal, so apps behave the same on both: character keys carry the character they type (`"A"` when shifted or under caps lock, `"!"` for shift+1) with `"shift"`, `"ctrl"`, `"alt"`, `"super"` modifiers in that order; special keys use the codes listed in `ExRatatui.Event.Key`; shift+tab is `"back_tab"`. Modifier keys alone produce no events.

  ## Layouts

  The built-in character table is a US layout. Pass `layout:` a map of `key_code => {unshifted, shifted}` to override or add keys (a German layout swaps `:key_y` and `:key_z`, for example).

  ## Examples

      iex> alias RasterExRatatui.Input.Evdev
      iex> {keyboard, []} = Evdev.translate(Evdev.new(), {:ev_key, :key_leftshift, 1})
      iex> {_keyboard, [key]} = Evdev.translate(keyboard, {:ev_key, :key_1, 1})
      iex> key
      %ExRatatui.Event.Key{code: "!", kind: "press", modifiers: ["shift"]}
  """

  alias ExRatatui.Event.Key

  @letters for c <- ?a..?z, into: %{}, do: {:"key_#{<<c>>}", {<<c>>, String.upcase(<<c>>)}}

  @us Map.merge(@letters, %{
        key_1: {"1", "!"},
        key_2: {"2", "@"},
        key_3: {"3", "#"},
        key_4: {"4", "$"},
        key_5: {"5", "%"},
        key_6: {"6", "^"},
        key_7: {"7", "&"},
        key_8: {"8", "*"},
        key_9: {"9", "("},
        key_0: {"0", ")"},
        key_minus: {"-", "_"},
        key_equal: {"=", "+"},
        key_leftbrace: {"[", "{"},
        key_rightbrace: {"]", "}"},
        key_backslash: {"\\", "|"},
        key_semicolon: {";", ":"},
        key_apostrophe: {"'", "\""},
        key_grave: {"`", "~"},
        key_comma: {",", "<"},
        key_dot: {".", ">"},
        key_slash: {"/", "?"},
        key_space: {" ", " "},
        key_kp0: {"0", "0"},
        key_kp1: {"1", "1"},
        key_kp2: {"2", "2"},
        key_kp3: {"3", "3"},
        key_kp4: {"4", "4"},
        key_kp5: {"5", "5"},
        key_kp6: {"6", "6"},
        key_kp7: {"7", "7"},
        key_kp8: {"8", "8"},
        key_kp9: {"9", "9"},
        key_kpdot: {".", "."},
        key_kpplus: {"+", "+"},
        key_kpminus: {"-", "-"},
        key_kpasterisk: {"*", "*"},
        key_kpslash: {"/", "/"}
      })

  @special %{
    key_enter: "enter",
    key_kpenter: "enter",
    key_esc: "esc",
    key_backspace: "backspace",
    key_tab: "tab",
    key_delete: "delete",
    key_insert: "insert",
    key_home: "home",
    key_end: "end",
    key_pageup: "page_up",
    key_pagedown: "page_down",
    key_up: "up",
    key_down: "down",
    key_left: "left",
    key_right: "right",
    key_capslock: "caps_lock",
    key_scrolllock: "scroll_lock",
    key_numlock: "num_lock",
    key_sysrq: "print_screen",
    key_pause: "pause",
    key_compose: "menu",
    key_f1: "f1",
    key_f2: "f2",
    key_f3: "f3",
    key_f4: "f4",
    key_f5: "f5",
    key_f6: "f6",
    key_f7: "f7",
    key_f8: "f8",
    key_f9: "f9",
    key_f10: "f10",
    key_f11: "f11",
    key_f12: "f12"
  }

  @modifiers %{
    key_leftshift: "shift",
    key_rightshift: "shift",
    key_leftctrl: "ctrl",
    key_rightctrl: "ctrl",
    key_leftalt: "alt",
    key_rightalt: "alt",
    key_leftmeta: "super",
    key_rightmeta: "super"
  }

  @modifier_order ["shift", "ctrl", "alt", "super"]

  @kinds %{0 => "release", 1 => "press", 2 => "repeat"}

  @type t :: %__MODULE__{
          held: MapSet.t(atom()),
          caps_lock: boolean(),
          emit_release: boolean(),
          chars: %{atom() => {String.t(), String.t()}}
        }

  defstruct held: MapSet.new(), caps_lock: false, emit_release: false, chars: @us

  @doc """
  A keyboard with no keys held and caps lock off.

  ## Options

    * `:layout` — `:us` (default) or a map of `key_code => {unshifted, shifted}` merged over the US table
    * `:emit_release` — also emit `kind: "release"` events (default `false`, like a terminal without keyboard enhancement)

  ## Examples

      iex> RasterExRatatui.Input.Evdev.new(layout: %{key_z: {"y", "Y"}}).chars.key_z
      {"y", "Y"}
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    chars =
      case Keyword.get(opts, :layout, :us) do
        :us -> @us
        layout when is_map(layout) -> Map.merge(@us, layout)
      end

    %__MODULE__{chars: chars, emit_release: Keyword.get(opts, :emit_release, false)}
  end

  @doc """
  Translates one evdev event. Events other than `:ev_key` (`:ev_syn`, `:ev_msc`, …) and keys with no mapping produce no keys.

  ## Examples

      iex> alias RasterExRatatui.Input.Evdev
      iex> {_keyboard, keys} = Evdev.translate(Evdev.new(), {:ev_key, :key_enter, 1})
      iex> keys
      [%ExRatatui.Event.Key{code: "enter", kind: "press", modifiers: []}]

      iex> alias RasterExRatatui.Input.Evdev
      iex> Evdev.translate(Evdev.new(), {:ev_syn, :syn_report, 0}) |> elem(1)
      []
  """
  @spec translate(t(), {atom(), atom(), integer()}) :: {t(), [Key.t()]}
  def translate(%__MODULE__{} = keyboard, {:ev_key, code, value})
      when is_map_key(@modifiers, code) do
    held =
      if value == 0, do: MapSet.delete(keyboard.held, code), else: MapSet.put(keyboard.held, code)

    {%{keyboard | held: held}, []}
  end

  def translate(%__MODULE__{} = keyboard, {:ev_key, code, value})
      when is_map_key(@kinds, value) do
    keyboard =
      if code == :key_capslock and value == 1, do: toggle_caps_lock(keyboard), else: keyboard

    if value == 0 and not keyboard.emit_release do
      {keyboard, []}
    else
      {keyboard, key(keyboard, code, Map.fetch!(@kinds, value))}
    end
  end

  def translate(%__MODULE__{} = keyboard, _event), do: {keyboard, []}

  @doc """
  Translates a list of evdev events in order, as delivered in one `{:input_event, path, events}` message.

  ## Examples

      iex> alias RasterExRatatui.Input.Evdev
      iex> events = [{:ev_key, :key_leftctrl, 1}, {:ev_msc, :msc_scan, 29}, {:ev_key, :key_c, 1}, {:ev_syn, :syn_report, 0}]
      iex> {_keyboard, keys} = Evdev.translate_all(Evdev.new(), events)
      iex> keys
      [%ExRatatui.Event.Key{code: "c", kind: "press", modifiers: ["ctrl"]}]
  """
  @spec translate_all(t(), [{atom(), atom(), integer()}]) :: {t(), [Key.t()]}
  def translate_all(%__MODULE__{} = keyboard, events) when is_list(events) do
    {keyboard, keys} =
      Enum.reduce(events, {keyboard, []}, fn event, {keyboard, acc} ->
        {keyboard, keys} = translate(keyboard, event)
        {keyboard, Enum.reverse(keys, acc)}
      end)

    {keyboard, Enum.reverse(keys)}
  end

  defp toggle_caps_lock(%__MODULE__{} = keyboard),
    do: %{keyboard | caps_lock: not keyboard.caps_lock}

  defp key(%__MODULE__{} = keyboard, code, kind) do
    modifiers = modifiers(keyboard)
    shift? = "shift" in modifiers

    case {Map.fetch(keyboard.chars, code), Map.fetch(@special, code)} do
      {{:ok, {plain, shifted}}, _} ->
        [
          %Key{
            code: char(plain, shifted, shift?, keyboard.caps_lock),
            kind: kind,
            modifiers: modifiers
          }
        ]

      {:error, {:ok, "tab"}} when shift? ->
        [%Key{code: "back_tab", kind: kind, modifiers: modifiers}]

      {:error, {:ok, special}} ->
        [%Key{code: special, kind: kind, modifiers: modifiers}]

      {:error, :error} ->
        []
    end
  end

  # Caps lock only affects letters, and shift undoes it.
  defp char(plain, shifted, shift?, caps_lock) do
    letter? = String.upcase(plain) == shifted and plain != shifted
    upper? = if letter?, do: shift? != caps_lock, else: shift?
    if upper?, do: shifted, else: plain
  end

  defp modifiers(%__MODULE__{held: held}) do
    active = MapSet.new(held, &Map.fetch!(@modifiers, &1))
    Enum.filter(@modifier_order, &MapSet.member?(active, &1))
  end
end
