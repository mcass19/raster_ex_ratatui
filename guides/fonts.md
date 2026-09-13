# Fonts

A panel has no font engine, so every cell symbol is painted from a bitmap. A font in this library is a module implementing `RasterExRatatui.Font`: a fixed cell size and one bitmap per codepoint.

## The glyph layout

`c:RasterExRatatui.Font.glyph/1` returns a bitstring of exactly `width * height` bits, row-major from the top-left pixel, most significant bit leftmost. A set bit is foreground, a clear bit is background.

```elixir
iex> alias RasterExRatatui.Font.{Art, Default6x8}
iex> Default6x8.glyph(?A) |> Art.render({6, 8}) |> IO.puts()
.###..
#...#.
#...#.
#####.
#...#.
#...#.
#...#.
......
```

`c:RasterExRatatui.Font.glyph/1` never fails. A codepoint the font does not cover returns a placeholder, so unsupported characters are visible in a rendering rather than silently blank; `c:RasterExRatatui.Font.has_glyph?/1` tells a real glyph from the placeholder.

## The built-in font

`RasterExRatatui.Font.Default6x8` was drawn for a 400×300 e-ink badge. Text glyphs are 5×7 with a blank column and row for spacing; box drawing (`─ │ ┌ ┐ └ ┘ ├ ┤ ┬ ┴ ┼`) and blocks (`█ ▀ ▄ ░ ▒ ▓`) fill the whole cell so they join. Braille, eighth blocks, and quadrants are generated, so `Canvas`, `Sparkline`, `BarChart`, `Gauge`, and `BigText` render faithfully. Anything else (accented letters, CJK, emoji, rounded or double box drawing) shows the hatched placeholder.

## Scale

`:scale` magnifies every glyph pixel into a square, so the 6×8 font at `scale: 3` paints 18×24 cells. The glyphs stay pixel-exact and blocky, which reads well from a distance; the cell grid shrinks accordingly (106×45 on a 1080p monitor).

The session is created with the effective cell (`RasterExRatatui.Raster.font_size/1`), so pixel regions from `Viewport3D` and `Image` are rendered at the panel's resolution, not magnified.

## Bringing a font

A font with a bigger cell needs its own glyph data. `RasterExRatatui.Font.Art` parses ASCII art at compile time, and `RasterExRatatui.Font.Generated` derives the geometric blocks for any cell size:

```elixir
defmodule MyApp.Font8x16 do
  @behaviour RasterExRatatui.Font

  alias RasterExRatatui.Font.{Art, Generated}

  @size {8, 16}

  @art %{
    ?A => """
    ........
    ...##...
    ..####..
    .##..##.
    ##....##
    ##....##
    ##....##
    ########
    ##....##
    ##....##
    ##....##
    ##....##
    ##....##
    ........
    """
  }

  # Drawn at 8×14; pad two blank rows at the bottom for line spacing.
  @hand_drawn Map.new(@art, fn {cp, art} -> {cp, Art.parse(art, @size, pad: {0, 2})} end)

  @glyphs [Generated.braille(@size), Generated.eighths(@size), Generated.quadrants(@size)]
          |> Enum.reduce(&Map.merge(&2, &1))
          |> Map.merge(@hand_drawn)

  @missing Generated.hatched(@size)

  @impl true
  def cell_size, do: @size

  @impl true
  def glyph(codepoint), do: Map.get(@glyphs, codepoint, @missing)

  @impl true
  def has_glyph?(codepoint), do: Map.has_key?(@glyphs, codepoint)
end
```

Public-domain and OFL bitmap fonts with good coverage exist (Unifont, Spleen, Terminus, the IBM VGA fonts); converting one to a module like this is a script away. The map lookup is the whole runtime cost, since the raster caches the packed pixels of every `{glyph, colours}` it has painted.

## Limits

- One codepoint per cell. A cell carrying a grapheme cluster (`e` plus a combining accent) is painted with its first codepoint.
- Wide characters (CJK, most emoji) occupy two terminal cells, but ratatui puts the symbol in the first cell only; a bitmap font paints it inside that one cell.
- There is no bold or italic face. The colour formats brighten bold text instead (see [Pixel Formats](pixel_formats.md)).
