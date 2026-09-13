defmodule RasterExRatatui.Palette do
  @moduledoc """
  Turns ExRatatui colour terms into RGB triples for colour panels.

  A cell's `fg` and `bg` are `t:ExRatatui.Style.color/0` terms: `:reset`, one of the 16 named ANSI colours, `{:indexed, 0..255}`, or `{:rgb, r, g, b}`. A terminal resolves the first three through its theme; a panel has no theme, so a palette carries one.

    * Named colours and indexed `0..15` come from the theme (xterm's defaults unless overridden).
    * Indexed `16..231` is the 6×6×6 colour cube and `232..255` the grayscale ramp, as in xterm.
    * `{:rgb, r, g, b}` is used as is.
    * `:reset` is the theme's default foreground or background, depending on which side of the cell it colours.

  ## Examples

      iex> alias RasterExRatatui.Palette
      iex> palette = Palette.new(reset_bg: {16, 16, 32}, theme: %{red: {255, 85, 85}})
      iex> Palette.rgb(:red, :fg, palette)
      {255, 85, 85}
      iex> Palette.rgb(:reset, :bg, palette)
      {16, 16, 32}
      iex> Palette.rgb({:indexed, 196}, :fg, palette)
      {255, 0, 0}
  """

  alias ExRatatui.CellSession.Cell

  @typedoc "An RGB triple, each channel `0..255`."
  @type rgb :: {0..255, 0..255, 0..255}

  @typedoc "Which side of the cell a colour paints, which decides what `:reset` means."
  @type role :: :fg | :bg

  @type t :: %__MODULE__{
          theme: %{atom() => rgb()},
          reset_fg: rgb(),
          reset_bg: rgb(),
          bold_bright: boolean()
        }

  defstruct [:theme, :reset_fg, :reset_bg, bold_bright: true]

  @names [
    :black,
    :red,
    :green,
    :yellow,
    :blue,
    :magenta,
    :cyan,
    :gray,
    :dark_gray,
    :light_red,
    :light_green,
    :light_yellow,
    :light_blue,
    :light_magenta,
    :light_cyan,
    :white
  ]

  @xterm %{
    black: {0, 0, 0},
    red: {205, 0, 0},
    green: {0, 205, 0},
    yellow: {205, 205, 0},
    blue: {0, 0, 238},
    magenta: {205, 0, 205},
    cyan: {0, 205, 205},
    gray: {229, 229, 229},
    dark_gray: {127, 127, 127},
    light_red: {255, 0, 0},
    light_green: {0, 255, 0},
    light_yellow: {255, 255, 0},
    light_blue: {92, 92, 255},
    light_magenta: {255, 0, 255},
    light_cyan: {0, 255, 255},
    white: {255, 255, 255}
  }

  @bright %{
    black: :dark_gray,
    red: :light_red,
    green: :light_green,
    yellow: :light_yellow,
    blue: :light_blue,
    magenta: :light_magenta,
    cyan: :light_cyan,
    gray: :white
  }

  @cube_levels {0, 95, 135, 175, 215, 255}

  @doc """
  Builds a palette.

  ## Options

    * `:theme` — a map of named colours to RGB, merged over xterm's defaults, so a partial map overrides only what it names.
    * `:reset_fg` — the default foreground (default `{229, 229, 229}`, xterm's `:gray`).
    * `:reset_bg` — the default background, also used for margins and skipped cells (default `{0, 0, 0}`).
    * `:bold_bright` — paint bold text with the bright variant of a dark named colour, as most terminals do (default `true`). A bitmap font has no bold face, so this is the only visible trace of `:bold`.

  Raises `ArgumentError` for a theme key that is not a named colour.

  ## Examples

      iex> RasterExRatatui.Palette.new().reset_bg
      {0, 0, 0}
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    theme = Keyword.get(opts, :theme, %{})

    case Map.keys(theme) -- @names do
      [] -> :ok
      unknown -> raise ArgumentError, "unknown theme colours: #{inspect(unknown)}"
    end

    %__MODULE__{
      theme: Map.merge(@xterm, theme),
      reset_fg: Keyword.get(opts, :reset_fg, @xterm.gray),
      reset_bg: Keyword.get(opts, :reset_bg, @xterm.black),
      bold_bright: Keyword.get(opts, :bold_bright, true)
    }
  end

  @doc """
  Resolves `color` to RGB. `role` only matters for `:reset`.

  ## Examples

      iex> alias RasterExRatatui.Palette
      iex> Palette.rgb({:rgb, 1, 2, 3}, :fg)
      {1, 2, 3}
      iex> Palette.rgb(:reset, :fg)
      {229, 229, 229}
      iex> Palette.rgb({:indexed, 9}, :fg)
      {255, 0, 0}
      iex> Palette.rgb({:indexed, 16 + 36 * 5 + 6 * 2 + 1}, :bg)
      {255, 135, 95}
      iex> Palette.rgb({:indexed, 244}, :bg)
      {128, 128, 128}
  """
  @spec rgb(ExRatatui.Style.color(), role(), t()) :: rgb()
  def rgb(color, role, palette \\ new())

  def rgb({:rgb, r, g, b}, _role, _palette), do: {r, g, b}
  def rgb(:reset, :fg, %__MODULE__{reset_fg: rgb}), do: rgb
  def rgb(:reset, :bg, %__MODULE__{reset_bg: rgb}), do: rgb
  def rgb(name, _role, %__MODULE__{theme: theme}) when is_atom(name), do: Map.fetch!(theme, name)

  def rgb({:indexed, n}, role, palette) when n in 0..15 do
    rgb(Enum.at(@names, n), role, palette)
  end

  def rgb({:indexed, n}, _role, _palette) when n in 16..231 do
    n = n - 16
    {level(div(n, 36)), level(rem(div(n, 6), 6)), level(rem(n, 6))}
  end

  def rgb({:indexed, n}, _role, _palette) when n in 232..255 do
    v = 8 + (n - 232) * 10
    {v, v, v}
  end

  @doc """
  The bright variant of a dark named colour (`:red` → `:light_red`, `:black` → `:dark_gray`, `:gray` → `:white`, indexed `0..7` → `8..15`). Every other colour is returned unchanged.

  ## Examples

      iex> RasterExRatatui.Palette.bright(:blue)
      :light_blue

      iex> RasterExRatatui.Palette.bright({:indexed, 3})
      {:indexed, 11}

      iex> RasterExRatatui.Palette.bright(:reset)
      :reset
  """
  @spec bright(ExRatatui.Style.color()) :: ExRatatui.Style.color()
  def bright({:indexed, n}) when n in 0..7, do: {:indexed, n + 8}
  def bright(name) when is_map_key(@bright, name), do: Map.fetch!(@bright, name)
  def bright(color), do: color

  @doc """
  A cell's `{foreground, background}` RGB, after its modifiers.

  `:bold` brightens a dark named foreground when the palette's `bold_bright` is on; `:reversed` then swaps the two sides. Other modifiers do not change colour.

  ## Examples

      iex> alias ExRatatui.CellSession.Cell
      iex> alias RasterExRatatui.Palette
      iex> Palette.cell_colors(%Cell{fg: :red, bg: :reset, modifiers: [:bold]}, Palette.new())
      {{255, 0, 0}, {0, 0, 0}}
      iex> Palette.cell_colors(%Cell{fg: :reset, bg: :blue, modifiers: [:reversed]}, Palette.new())
      {{0, 0, 238}, {229, 229, 229}}
  """
  @spec cell_colors(Cell.t(), t()) :: {rgb(), rgb()}
  def cell_colors(%Cell{fg: fg, bg: bg, modifiers: modifiers}, %__MODULE__{} = palette) do
    fg = if palette.bold_bright and :bold in modifiers, do: bright(fg), else: fg
    colors = {rgb(fg, :fg, palette), rgb(bg, :bg, palette)}

    if :reversed in modifiers do
      {elem(colors, 1), elem(colors, 0)}
    else
      colors
    end
  end

  defp level(i), do: elem(@cube_levels, i)
end
