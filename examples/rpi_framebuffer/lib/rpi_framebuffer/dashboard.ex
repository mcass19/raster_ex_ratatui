defmodule RpiFramebuffer.Dashboard do
  @moduledoc """
  The app on the panel: a tab bar, the active tab, and a hint line.

      ╭ raster_ex_ratatui ───────────────────────────────╮
      │ Showcase │ Input                                 │
      ╰──────────────────────────────────────────────────╯
      ┌──────────────────────────────────────────────────┐
      │                  the active tab                  │
      └──────────────────────────────────────────────────┘
       s shape  p photo  space pause  tab next  ctrl+q quit

  It is an ordinary `ExRatatui.App` on the reducer runtime and knows nothing about pixels: `RpiFramebuffer.Surface` runs it on the framebuffer, `RpiFramebuffer.run/1` in a terminal. Each tab is a `RpiFramebuffer.Dashboard.Tab`; the dashboard keeps their states, routes their timer messages back to them, and hands key events to the one on screen.

  A tab that updates while off screen (a timer message that still arrives) does not cause a render.

  ## Keys

  | Key                | Action                                                         |
  | ------------------ | -------------------------------------------------------------- |
  | `tab` / `back_tab` | Next / previous tab                                            |
  | `f1`, `f2`         | Jump to a tab                                                  |
  | `ctrl+q`           | Quit                                                           |
  | `q`                | Quit, on tabs that do not use the key (the Input tab types it) |

  Quitting stops the app. On the device the surface starts a fresh one, since the panel has nothing else to show.

  ## Touch

  On a touch panel a tap on a tab's title switches to it (`tab_at/1`); everything else the finger does below the tab bar goes to the tab on screen, as `ExRatatui.Event.Mouse` events on cells, like a mouse in a terminal.

  ## Options

  Every option is handed to every tab: `:spin_ms` (see `RpiFramebuffer.Dashboard.Showcase`) and, on a panel, the `surface:` map a `RasterExRatatui` surface adds, with the cell size the layouts use (`RpiFramebuffer.Dashboard.Tab.cell_size/1`).
  """

  use ExRatatui.App, runtime: :reducer

  alias ExRatatui.Event.Key
  alias ExRatatui.Event.Mouse
  alias ExRatatui.Event.Resize
  alias ExRatatui.Layout
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Style
  alias ExRatatui.Text.Line
  alias ExRatatui.Text.Span
  alias ExRatatui.Widgets.Block
  alias ExRatatui.Widgets.Paragraph
  alias ExRatatui.Widgets.Tabs
  alias RpiFramebuffer.Dashboard.Input
  alias RpiFramebuffer.Dashboard.Showcase

  @tabs [Showcase, Input]
  @jump %{"f1" => 0, "f2" => 1}
  @bar_height 3

  @impl ExRatatui.App
  def init(opts) do
    {:ok, %{active: 0, tabs: Map.new(@tabs, &{&1, &1.init(opts)})}}
  end

  @impl ExRatatui.App
  def update({:event, %Key{code: "q", kind: "press", modifiers: ["ctrl"]}}, state),
    do: {:stop, state}

  def update({:event, %Key{code: "tab", kind: "press"}}, state),
    do: {:noreply, %{state | active: turn(state.active, 1)}}

  def update({:event, %Key{code: "back_tab", kind: "press"}}, state),
    do: {:noreply, %{state | active: turn(state.active, -1)}}

  def update({:event, %Key{code: code, kind: "press", modifiers: []}}, state)
      when is_map_key(@jump, code),
      do: {:noreply, %{state | active: Map.fetch!(@jump, code)}}

  def update({:event, %Resize{}}, state), do: {:noreply, state}

  # The tab bar is the dashboard's: a finger landing on a title switches tabs,
  # and nothing a finger does there reaches a tab.
  def update({:event, %Mouse{y: y} = mouse}, state) when y < @bar_height do
    case {mouse.kind, tab_at(mouse.x)} do
      {"down", index} when is_integer(index) and index != state.active ->
        {:noreply, %{state | active: index}}

      _elsewhere ->
        {:noreply, state, render?: false}
    end
  end

  def update({:event, event}, state) do
    tab = active(state)

    case {tab.update({:event, event}, state.tabs[tab]), event} do
      {{:ok, tab_state}, _event} -> {:noreply, put_in(state.tabs[tab], tab_state)}
      {:ignored, %Key{code: "q", kind: "press", modifiers: []}} -> {:stop, state}
      {:ignored, _event} -> {:noreply, state, render?: false}
    end
  end

  def update({:info, {:tab, tab, message}}, state) when is_map_key(state.tabs, tab) do
    case tab.update({:info, message}, state.tabs[tab]) do
      {:ok, tab_state} ->
        state = put_in(state.tabs[tab], tab_state)
        if tab == active(state), do: {:noreply, state}, else: {:noreply, state, render?: false}

      :ignored ->
        {:noreply, state, render?: false}
    end
  end

  def update(_message, state), do: {:noreply, state, render?: false}

  @impl ExRatatui.App
  def subscriptions(state) do
    Enum.flat_map(@tabs, & &1.subscriptions(state.tabs[&1], &1 == active(state)))
  end

  @doc """
  The module of the tab on screen.
  """
  @spec active(map()) :: module()
  def active(state), do: Enum.at(@tabs, state.active)

  @doc """
  The tab index `step` tabs away from `index`, wrapping at both ends.

  ## Examples

      iex> RpiFramebuffer.Dashboard.turn(1, 1)
      0

      iex> RpiFramebuffer.Dashboard.turn(0, -1)
      1
  """
  @spec turn(non_neg_integer(), integer()) :: non_neg_integer()
  def turn(index, step), do: Integer.mod(index + step, length(@tabs))

  @doc """
  The index of the tab whose title is at column `x` of the tab bar, or `nil` for the border, a divider, or the empty rest of the bar.

  The bar draws, after its one-column border, each title padded by a space on both sides, with a one-column divider between two titles: `│ Showcase │ Input │`.

  ## Examples

      iex> Enum.map([0, 1, 10, 11, 12, 18, 19], &RpiFramebuffer.Dashboard.tab_at/1)
      [nil, 0, 0, nil, 1, 1, nil]
  """
  @spec tab_at(integer()) :: non_neg_integer() | nil
  def tab_at(x) do
    @tabs
    |> Enum.map(&(String.length(&1.title()) + 2))
    |> Enum.with_index()
    |> Enum.reduce_while(1, fn {width, index}, start ->
      if x >= start and x < start + width,
        do: {:halt, {:found, index}},
        else: {:cont, start + width + 1}
    end)
    |> case do
      {:found, index} -> index
      _past_the_titles -> nil
    end
  end

  @impl ExRatatui.App
  def render(state, %{width: width, height: height}) do
    area = %Rect{x: 0, y: 0, width: width, height: height}

    [bar, body, hints] =
      Layout.split(area, :vertical, [{:length, @bar_height}, {:fill, 1}, {:length, 1}])

    tab = active(state)

    tabs = %Tabs{
      titles: Enum.map(@tabs, & &1.title()),
      selected: state.active,
      style: %Style{fg: :gray},
      # No :bold here: the raster brightens bold colours, and bright black on cyan is hard to read.
      highlight_style: %Style{fg: :black, bg: :light_cyan},
      block: %Block{
        title: " raster_ex_ratatui ",
        borders: [:all],
        border_type: :rounded,
        border_style: %Style{fg: :dark_gray}
      }
    }

    [{tabs, bar}] ++
      tab.render(state.tabs[tab], body) ++
      [{hint_line(tab.hints(state.tabs[tab])), hints}]
  end

  defp hint_line(tab_hints) do
    spans =
      Enum.flat_map(tab_hints ++ [{"tab", "next"}, {"ctrl+q", "quit"}], fn {key, action} ->
        [
          %Span{content: " #{key}", style: %Style{fg: :light_yellow, modifiers: [:bold]}},
          %Span{content: " #{action} ", style: %Style{fg: :gray}}
        ]
      end)

    %Paragraph{text: %Line{spans: spans}}
  end
end
