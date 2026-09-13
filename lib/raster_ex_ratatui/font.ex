defmodule RasterExRatatui.Font do
  @moduledoc """
  Behaviour for a monospace bitmap font: a fixed cell size and one bitmap per codepoint.

  A panel has no font engine, so every cell symbol is painted from a bitmap. The font decides the size of a cell in pixels (before the raster's integer `scale:`), which in turn decides how many cells fit on the panel.

  ## Glyph layout

  `c:glyph/1` returns a bitstring of exactly `width * height` bits, row-major from the top-left pixel: the first `width` bits are the top row, and within a row the most significant bit is the leftmost pixel. A set bit is foreground ("ink"), a clear bit is background.

      iex> alias RasterExRatatui.Font
      iex> {w, h} = Font.Default6x8.cell_size()
      iex> bits = Font.Default6x8.glyph(?T)
      iex> bit_size(bits) == w * h
      true
      iex> Font.Art.render(bits, {w, h}) |> String.split("\\n", trim: true) |> Enum.take(2)
      ["#####.", "..#..."]

  Text glyphs usually leave a column and a row blank as inter-cell spacing; box-drawing, block, and braille glyphs fill the whole cell so they join across cell boundaries.

  `c:glyph/1` never fails: a codepoint the font does not cover returns a visible placeholder (`RasterExRatatui.Font.Generated.hatched/1` is a good one), so unsupported characters show up in renderings instead of silently vanishing. `c:has_glyph?/1` tells the two apart.

  ## Implementing a font

  `RasterExRatatui.Font.Art` parses ASCII art into glyph bitstrings at compile time and `RasterExRatatui.Font.Generated` derives braille, eighth blocks, and quadrants for any cell size, so a new font is mostly glyph data:

      defmodule MyFont do
        @behaviour RasterExRatatui.Font

        alias RasterExRatatui.Font.{Art, Generated}

        @size {8, 12}
        @glyphs Map.merge(Generated.braille(@size), %{?A => Art.parse(@a_art, @size)})
        @missing Generated.hatched(@size)

        @impl true
        def cell_size, do: @size

        @impl true
        def glyph(codepoint), do: Map.get(@glyphs, codepoint, @missing)

        @impl true
        def has_glyph?(codepoint), do: Map.has_key?(@glyphs, codepoint)
      end
  """

  @typedoc "A module implementing this behaviour."
  @type t :: module()

  @typedoc "A glyph bitmap: `width * height` bits, row-major, most significant bit leftmost."
  @type glyph :: bitstring()

  @doc "Cell size in pixels, as `{width, height}`."
  @callback cell_size() :: {pos_integer(), pos_integer()}

  @doc "The bitmap for `codepoint`, or a placeholder when the font does not cover it."
  @callback glyph(codepoint :: non_neg_integer()) :: glyph()

  @doc "Whether the font has a real glyph (not the placeholder) for `codepoint`."
  @callback has_glyph?(codepoint :: non_neg_integer()) :: boolean()

  @optional_callbacks has_glyph?: 1

  @doc """
  The codepoint a cell symbol is painted with: its first codepoint, or a space for an empty symbol.

  Cells carry grapheme clusters (`"é"` may arrive as `e` plus a combining accent); a bitmap font paints the base character.

  ## Examples

      iex> RasterExRatatui.Font.codepoint("A")
      ?A

      iex> RasterExRatatui.Font.codepoint("e\\u0301")
      ?e

      iex> RasterExRatatui.Font.codepoint("")
      ?\\s
  """
  @spec codepoint(String.t()) :: non_neg_integer()
  def codepoint(<<cp::utf8, _::binary>>), do: cp
  def codepoint(_symbol), do: ?\s
end
