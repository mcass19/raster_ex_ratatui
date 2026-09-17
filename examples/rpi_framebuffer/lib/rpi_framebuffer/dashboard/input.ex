defmodule RpiFramebuffer.Dashboard.Input do
  @moduledoc """
  Proof that the keyboard arrives whole: a text input to type into, the last key with its modifiers spelled out, the keys before it, and the lines sent with `enter`.

  On the device every event here started as an evdev tuple from `input_event`, became an `ExRatatui.Event.Key` in `RasterExRatatui.Input.Evdev` (shift and caps lock applied, modifiers tracked), and reached the app through the surface. In a terminal the same tab shows what crossterm reports, which makes the two easy to compare.

  Plain and shifted keys go to the text input. Anything held with `ctrl`, `alt`, or `super` only shows up as the last key, so chords can be tried without typing garbage. Releases are ignored; repeats of a held key count as typing.

  ## Keys

  | Key     | Action                          |
  | ------- | ------------------------------- |
  | `enter` | Send the line to the echo pane  |
  | `esc`   | Clear the line                  |
  """

  @behaviour RpiFramebuffer.Dashboard.Tab

  alias ExRatatui.Event.Key
  alias ExRatatui.Layout
  alias ExRatatui.Style
  alias ExRatatui.Text.Line
  alias ExRatatui.Text.Span
  alias ExRatatui.Widgets.Block
  alias ExRatatui.Widgets.Paragraph
  alias ExRatatui.Widgets.TextInput
  alias RpiFramebuffer.Dashboard.Tab

  @history 200
  @editing ~w(backspace delete left right home end)

  @impl Tab
  def title, do: "Input"

  @impl Tab
  def init(_opts) do
    %{field: ExRatatui.text_input_new(), last: nil, count: 0, recent: [], echo: []}
  end

  @impl Tab
  def update({:event, %Key{kind: kind} = key}, state) when kind in ["press", "repeat"] do
    {:ok, state |> note(key) |> type(key)}
  end

  def update(_message, _state), do: :ignored

  @impl Tab
  def subscriptions(_state, _active?), do: []

  @impl Tab
  def hints(_state), do: [{"enter", "echo"}, {"esc", "clear"}]

  defp note(state, key) do
    %{state | last: key, count: state.count + 1, recent: Tab.push(state.recent, key, @history)}
  end

  defp type(state, %Key{code: "enter", modifiers: []}) do
    case ExRatatui.text_input_get_value(state.field) do
      "" ->
        state

      line ->
        :ok = ExRatatui.text_input_set_value(state.field, "")
        %{state | echo: Tab.push(state.echo, line, @history)}
    end
  end

  defp type(state, %Key{code: "esc", modifiers: []}) do
    :ok = ExRatatui.text_input_set_value(state.field, "")
    state
  end

  defp type(state, %Key{code: code} = key) do
    if typing?(key), do: :ok = ExRatatui.text_input_handle_key(state.field, code)
    state
  end

  @doc """
  Whether a key edits the text input: a single character or an editing key, held with nothing but `shift`.

  ## Examples

      iex> alias ExRatatui.Event.Key
      iex> RpiFramebuffer.Dashboard.Input.typing?(%Key{code: "A", kind: "press", modifiers: ["shift"]})
      true
      iex> RpiFramebuffer.Dashboard.Input.typing?(%Key{code: "backspace", kind: "repeat", modifiers: []})
      true
      iex> RpiFramebuffer.Dashboard.Input.typing?(%Key{code: "a", kind: "press", modifiers: ["ctrl"]})
      false
      iex> RpiFramebuffer.Dashboard.Input.typing?(%Key{code: "f5", kind: "press", modifiers: []})
      false
  """
  @spec typing?(Key.t()) :: boolean()
  def typing?(%Key{code: code, modifiers: modifiers}) do
    modifiers -- ["shift"] == [] and (code in @editing or String.length(code) == 1)
  end

  @doc """
  A key as a chord: modifiers, then the code, with the space bar named.

  ## Examples

      iex> alias ExRatatui.Event.Key
      iex> RpiFramebuffer.Dashboard.Input.chord(%Key{code: "A", kind: "press", modifiers: ["shift", "ctrl"]})
      "shift+ctrl+A"
      iex> RpiFramebuffer.Dashboard.Input.chord(%Key{code: " ", kind: "press", modifiers: []})
      "space"
  """
  @spec chord(Key.t()) :: String.t()
  def chord(%Key{code: code, modifiers: modifiers}) do
    Enum.join(modifiers ++ [if(code == " ", do: "space", else: code)], "+")
  end

  @impl Tab
  def render(state, area) do
    [field, last, logs] = Layout.split(area, :vertical, [{:length, 3}, {:length, 6}, {:fill, 1}])
    [recent, echo] = Layout.split(logs, :horizontal, [{:fill, 1}, {:fill, 1}])

    input = %TextInput{
      state: state.field,
      placeholder: "type on the keyboard",
      placeholder_style: %Style{fg: :dark_gray},
      cursor_style: %Style{modifiers: [:reversed]},
      block: pane(" Type here ", :light_cyan)
    }

    [
      {input, field},
      {pane(" Last key ", :light_yellow), last},
      {%Paragraph{text: last_lines(state)}, Tab.inner(last)},
      {pane(" Keys (#{state.count}) ", :light_green), recent},
      {%Paragraph{text: newest(state.recent, recent, &recent_line/1)}, Tab.inner(recent)},
      {pane(" Echo ", :light_magenta), echo},
      {%Paragraph{text: newest(state.echo, echo, &%Line{spans: [%Span{content: &1}]})},
       Tab.inner(echo)}
    ]
  end

  defp last_lines(%{last: nil}), do: [field_line("code", "press any key", :dark_gray)]

  defp last_lines(%{last: %Key{} = key}) do
    modifiers = if key.modifiers == [], do: "none", else: Enum.join(key.modifiers, " ")

    [
      field_line("chord", chord(key), :light_yellow),
      field_line("code", inspect(key.code), :white),
      field_line("kind", key.kind, :white),
      field_line("modifiers", modifiers, :white)
    ]
  end

  defp field_line(label, value, color) do
    %Line{
      spans: [
        %Span{content: String.pad_trailing(label, 11), style: %Style{fg: :gray}},
        %Span{content: value, style: %Style{fg: color}}
      ]
    }
  end

  defp recent_line(%Key{} = key) do
    %Line{
      spans: [
        %Span{content: String.pad_trailing(key.kind, 7), style: %Style{fg: :gray}},
        %Span{content: chord(key)}
      ]
    }
  end

  # The newest entries that fit the pane, newest first.
  defp newest(history, pane, line) do
    rows = Tab.inner(pane).height
    history |> Enum.take(-rows) |> Enum.reverse() |> Enum.map(line)
  end

  defp pane(title, color) do
    %Block{title: title, borders: [:all], border_type: :rounded, border_style: %Style{fg: color}}
  end
end
