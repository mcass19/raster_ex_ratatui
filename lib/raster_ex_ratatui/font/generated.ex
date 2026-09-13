defmodule RasterExRatatui.Font.Generated do
  @moduledoc """
  Glyphs derived from their Unicode geometry instead of drawn by hand, for any cell size.

  Braille patterns, eighth blocks, and quadrants are exact subdivisions of the cell, so a font gets them for free: each function returns a `%{codepoint => glyph}` map for a `{width, height}` cell, ready to merge under the hand-drawn glyphs (hand-drawn wins on conflict when merged second).

  Widgets lean on these: `Canvas` draws with braille by default, `Sparkline` and `BarChart` with eighth blocks, `BigText` with quadrants.
  """

  import Bitwise

  @type size :: {pos_integer(), pos_integer()}

  @doc """
  The braille block `U+2800..U+28FF`.

  The cell splits into two dot columns and four dot rows; each lit dot fills its whole sub-rectangle, so neighbouring dots merge into continuous lines rather than a dotted texture. Bit `n` of the codepoint offset lights dot `n + 1`: dots 1-2-3 run down the left column, 4-5-6 down the right, 7 and 8 are the bottom row.

  ## Examples

      iex> glyphs = RasterExRatatui.Font.Generated.braille({2, 4})
      iex> map_size(glyphs)
      256
      iex> RasterExRatatui.Font.Art.render(glyphs[0x2801], {2, 4})
      "#.\\n..\\n..\\n..\\n"
      iex> RasterExRatatui.Font.Art.render(glyphs[0x2880], {2, 4})
      "..\\n..\\n..\\n.#\\n"
  """
  @spec braille(size()) :: %{non_neg_integer() => bitstring()}
  def braille({width, height} = size) do
    dots = [{0, 0}, {0, 1}, {0, 2}, {1, 0}, {1, 1}, {1, 2}, {0, 3}, {1, 3}]

    for cp <- 0x2800..0x28FF, into: %{} do
      lit = for {dot, bit} <- Enum.with_index(dots), (cp - 0x2800 &&& 1 <<< bit) != 0, do: dot
      {cp, rasterise(size, fn x, y -> {div(x * 2, width), div(y * 4, height)} in lit end)}
    end
  end

  @doc """
  Eighth blocks: lower `▁..▇` (`U+2581..U+2587`), left `▏..▉` (`U+2589..U+258F`), the right half `▐`, the upper eighth `▔`, and the right eighth `▕`.

  Fractions round to whole pixel rows or columns of the cell; the thin edges are at least one pixel.

  ## Examples

      iex> glyphs = RasterExRatatui.Font.Generated.eighths({4, 8})
      iex> RasterExRatatui.Font.Art.render(glyphs[0x2583], {4, 8}) |> String.split("\\n", trim: true) |> Enum.drop(4)
      ["....", "####", "####", "####"]
      iex> RasterExRatatui.Font.Art.render(glyphs[0x258C], {4, 8}) |> String.split("\\n", trim: true) |> hd()
      "##.."
  """
  @spec eighths(size()) :: %{non_neg_integer() => bitstring()}
  def eighths({width, height} = size) do
    lower =
      for k <- 1..7, into: %{} do
        rows = round(height * k / 8)
        {0x2580 + k, rasterise(size, fn _x, y -> y >= height - rows end)}
      end

    left =
      for k <- 1..7, into: %{} do
        cols = round(width * k / 8)
        {0x2590 - k, rasterise(size, fn x, _y -> x < cols end)}
      end

    thin_row = max(1, round(height / 8))
    thin_col = max(1, round(width / 8))

    edges = %{
      0x2590 => rasterise(size, fn x, _y -> x >= div(width, 2) end),
      0x2594 => rasterise(size, fn _x, y -> y < thin_row end),
      0x2595 => rasterise(size, fn x, _y -> x >= width - thin_col end)
    }

    lower |> Map.merge(left) |> Map.merge(edges)
  end

  @doc """
  The quadrant blocks `▖ ▗ ▘ ▙ ▚ ▛ ▜ ▝ ▞ ▟` (`U+2596..U+259F`), splitting the cell at half its width and height.

  ## Examples

      iex> glyphs = RasterExRatatui.Font.Generated.quadrants({2, 2})
      iex> RasterExRatatui.Font.Art.render(glyphs[0x259A], {2, 2})
      "#.\\n.#\\n"
  """
  @spec quadrants(size()) :: %{non_neg_integer() => bitstring()}
  def quadrants({width, height} = size) do
    corners = %{
      0x2596 => [:lower_left],
      0x2597 => [:lower_right],
      0x2598 => [:upper_left],
      0x2599 => [:upper_left, :lower_left, :lower_right],
      0x259A => [:upper_left, :lower_right],
      0x259B => [:upper_left, :upper_right, :lower_left],
      0x259C => [:upper_left, :upper_right, :lower_right],
      0x259D => [:upper_right],
      0x259E => [:upper_right, :lower_left],
      0x259F => [:upper_right, :lower_left, :lower_right]
    }

    Map.new(corners, fn {cp, lit} ->
      {cp, rasterise(size, fn x, y -> corner(x < div(width, 2), y < div(height, 2)) in lit end)}
    end)
  end

  @doc """
  A hatched checkerboard with a blank bottom row: the conventional "no glyph for this codepoint" placeholder, visibly different from a space.

  ## Examples

      iex> RasterExRatatui.Font.Art.render(RasterExRatatui.Font.Generated.hatched({4, 3}), {4, 3})
      "#.#.\\n.#.#\\n....\\n"
  """
  @spec hatched(size()) :: bitstring()
  def hatched({_width, height} = size) do
    rasterise(size, fn x, y -> y < height - 1 and rem(x + y, 2) == 0 end)
  end

  @doc """
  Builds a `{width, height}` glyph from a per-pixel predicate `ink?.(x, y)`.

  ## Examples

      iex> RasterExRatatui.Font.Generated.rasterise({3, 1}, fn x, _y -> x != 1 end)
      <<0b101::3>>
  """
  @spec rasterise(size(), (non_neg_integer(), non_neg_integer() -> boolean())) :: bitstring()
  def rasterise({width, height}, ink?) when is_function(ink?, 2) do
    for y <- 0..(height - 1), x <- 0..(width - 1), into: <<>> do
      if ink?.(x, y), do: <<1::1>>, else: <<0::1>>
    end
  end

  defp corner(true, true), do: :upper_left
  defp corner(false, true), do: :upper_right
  defp corner(true, false), do: :lower_left
  defp corner(false, false), do: :lower_right
end
