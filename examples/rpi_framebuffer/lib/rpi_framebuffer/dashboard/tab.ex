defmodule RpiFramebuffer.Dashboard.Tab do
  @moduledoc """
  One tab of `RpiFramebuffer.Dashboard`: a slice of reducer state with its own messages, timers, and widgets.

  The dashboard owns the tab bar and the hint line; a tab renders into the rect between them and never assumes its size, so the same tab holds on a 60×80 portrait grid and a 106×45 landscape one.
  """

  alias ExRatatui.Layout.Rect
  alias ExRatatui.Subscription

  @typedoc "A tab's private state."
  @type state :: term()

  @doc "The title shown in the tab bar."
  @callback title() :: String.t()

  @doc "Builds the tab's state from the dashboard's options."
  @callback init(opts :: keyword()) :: state()

  @doc """
  Handles `{:event, event}` (only while the tab is active) or `{:info, message}` (a message from one of the tab's subscriptions, active or not).

  Returns `:ignored` when nothing changed, so the dashboard skips the render.
  """
  @callback update(message :: {:event, ExRatatui.Event.t()} | {:info, term()}, state()) ::
              {:ok, state()} | :ignored

  @doc """
  The tab's timers. Messages are wrapped with `message/2` so the dashboard routes them back. `active?` lets a tab stop animating while it is not on screen.
  """
  @callback subscriptions(state(), active? :: boolean()) :: [Subscription.t()]

  @doc "The widgets for `area`."
  @callback render(state(), area :: Rect.t()) :: [{struct(), Rect.t()}]

  @doc "The `{key, action}` pairs for the hint line."
  @callback hints(state()) :: [{String.t(), String.t()}]

  @doc """
  Wraps a subscription message so it comes back to `tab`.

  ## Examples

      iex> RpiFramebuffer.Dashboard.Tab.message(MyTab, :tick)
      {:tab, MyTab, :tick}
  """
  @spec message(module(), term()) :: {:tab, module(), term()}
  def message(tab, message), do: {:tab, tab, message}

  @doc """
  The rect inside a bordered block.

  ## Examples

      iex> RpiFramebuffer.Dashboard.Tab.inner(%ExRatatui.Layout.Rect{x: 0, y: 3, width: 60, height: 20})
      %ExRatatui.Layout.Rect{x: 1, y: 4, width: 58, height: 18}

      iex> RpiFramebuffer.Dashboard.Tab.inner(%ExRatatui.Layout.Rect{x: 0, y: 0, width: 1, height: 1})
      %ExRatatui.Layout.Rect{x: 1, y: 1, width: 0, height: 0}
  """
  @spec inner(Rect.t()) :: Rect.t()
  def inner(%Rect{x: x, y: y, width: width, height: height}) do
    %Rect{x: x + 1, y: y + 1, width: max(width - 2, 0), height: max(height - 2, 0)}
  end

  @doc """
  Whether `area` is wider than tall on the panel, given the cell size in pixels (`cell_size` in the `surface:` option a surface gives the app; 6×8 in a terminal).

  ## Examples

      iex> RpiFramebuffer.Dashboard.Tab.landscape?(%ExRatatui.Layout.Rect{width: 106, height: 41}, {6, 8})
      true

      iex> RpiFramebuffer.Dashboard.Tab.landscape?(%ExRatatui.Layout.Rect{width: 60, height: 76}, {6, 8})
      false
  """
  @spec landscape?(Rect.t(), {pos_integer(), pos_integer()}) :: boolean()
  def landscape?(%Rect{width: width, height: height}, {cell_w, cell_h}),
    do: width * cell_w > height * cell_h

  @doc """
  The cell size in pixels from an app's options: the `surface:` a `RasterExRatatui` surface adds, or the library font's 6×8 in a terminal.

  ## Examples

      iex> RpiFramebuffer.Dashboard.Tab.cell_size(surface: %{cell_size: {12, 16}})
      {12, 16}

      iex> RpiFramebuffer.Dashboard.Tab.cell_size([])
      {6, 8}
  """
  @spec cell_size(keyword()) :: {pos_integer(), pos_integer()}
  def cell_size(opts) do
    case Keyword.get(opts, :surface) do
      %{cell_size: cell_size} -> cell_size
      _none -> {6, 8}
    end
  end

  @doc """
  Appends `value` to `history`, keeping the last `limit` entries.

  ## Examples

      iex> RpiFramebuffer.Dashboard.Tab.push([1, 2, 3], 4, 3)
      [2, 3, 4]
  """
  @spec push([term()], term(), pos_integer()) :: [term()]
  def push(history, value, limit), do: Enum.take(history ++ [value], -limit)

  @doc """
  The tail of `history` that fits `area`: a sparkline draws its data from the left and drops what overflows, which would hide the newest samples.

  ## Examples

      iex> RpiFramebuffer.Dashboard.Tab.fit([1, 2, 3, 4], %ExRatatui.Layout.Rect{width: 2, height: 1})
      [3, 4]
  """
  @spec fit([term()], Rect.t()) :: [term()]
  def fit(_history, %Rect{width: 0}), do: []
  def fit(history, %Rect{width: width}), do: Enum.take(history, -width)
end
