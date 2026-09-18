defmodule RasterExRatatui.PixelFormat.Mono do
  @moduledoc """
  One gray byte per pixel for 1-bit panels: `0` is ink, `255` is paper.

  A 1-bit panel cannot show colour, so every colour collapses to a *tone*: ink, paper, or gray (a pixel checkerboard). The bytes are gray8 so they can be thresholded, PNG-encoded, or bit-packed by the driver; every pixel is exactly `0` or `255`.

  ## Cells

  The glyph's set bits take the foreground tone and the rest of the cell the background tone, which keeps half-block cells honest: `▀` with a dark `fg` and a light `bg` inks only its top half, which is what `Canvas`'s `:half_block` marker emits.

  | Colour | as `fg` | as `bg` |
  | ------ | ------- | ------- |
  | `:black` | ink | ink |
  | `:reset`, other named, indexed | ink on a paper `bg`, paper on an ink `bg` | paper |
  | `{:rgb, r, g, b}` | by luma: ink / gray / paper | same |

  `:reversed` short-circuits all of that and always paints a paper glyph on an ink cell: screens stack it with a `bg: :black` fill to invert a whole frame. Named colours keep terminal legibility: a red or white label is ink on paper and paper on an ink fill, and `bg: :white` (which `Canvas` emits for shape cells) is plain paper. RGB colours are treated as intent: dark is ink, light is paper, and the band between `:ink_max` and `:paper_min` (Rec. 601 luma) is gray, so lit and shadowed faces read as three tones. Other modifiers are ignored.

  ## Regions

  Region pixels go through a Bayer 4×4 ordered dither on luma. The tile repeats across the panel, so the texture is stable between frames and under partial refresh, without the crawling noise error diffusion shows.

  ## Options

    * `:ink_max` — RGB colours with luma at or below this are ink (default `76`, 30%)
    * `:paper_min` — RGB colours with luma at or above this are paper (default `178`, 70%)

  ## Examples

      iex> alias ExRatatui.CellSession.Cell
      iex> alias RasterExRatatui.PixelFormat.Mono
      iex> config = Mono.init([])
      iex> Mono.cell_paints(%Cell{fg: :red, bg: :reset}, config)
      {<<0>>, <<255>>}
      iex> Mono.cell_paints(%Cell{fg: :red, bg: :black}, config)
      {<<255>>, <<0>>}
      iex> Mono.cell_paints(%Cell{fg: {:rgb, 128, 128, 128}, bg: :reset}, config)
      {{:checker, <<0>>, <<255>>}, <<255>>}
  """

  @behaviour RasterExRatatui.PixelFormat

  alias ExRatatui.CellSession.Cell

  @ink <<0>>
  @paper <<255>>
  @gray {:checker, @ink, @paper}

  @bayer {
    {0, 8, 2, 10},
    {12, 4, 14, 6},
    {3, 11, 1, 9},
    {15, 7, 13, 5}
  }

  @impl true
  @doc """
  Reads `:ink_max` and `:paper_min`.

  ## Examples

      iex> RasterExRatatui.PixelFormat.Mono.init(ink_max: 50)
      %{ink_max: 50, paper_min: 178}
  """
  @spec init(keyword()) :: %{ink_max: 0..255, paper_min: 0..255}
  def init(opts) do
    %{ink_max: Keyword.get(opts, :ink_max, 76), paper_min: Keyword.get(opts, :paper_min, 178)}
  end

  @impl true
  @doc """
  One byte per pixel.

  ## Examples

      iex> RasterExRatatui.PixelFormat.Mono.bytes_per_pixel(%{})
      1
  """
  @spec bytes_per_pixel(term()) :: 1
  def bytes_per_pixel(_config), do: 1

  @impl true
  @doc """
  Foreground and background tones for a cell; see the moduledoc table.

  ## Examples

      iex> alias ExRatatui.CellSession.Cell
      iex> RasterExRatatui.PixelFormat.Mono.cell_paints(%Cell{bg: :blue, modifiers: [:reversed]}, RasterExRatatui.PixelFormat.Mono.init([]))
      {<<255>>, <<0>>}
  """
  @spec cell_paints(Cell.t(), map()) ::
          {RasterExRatatui.PixelFormat.paint(), RasterExRatatui.PixelFormat.paint()}
  def cell_paints(%Cell{modifiers: modifiers} = cell, config) do
    if :reversed in modifiers do
      {@paper, @ink}
    else
      bg = bg_tone(cell.bg, config)
      {fg_tone(cell.fg, bg, config), bg}
    end
  end

  @impl true
  @doc """
  Dithers an RGB pixel to ink or paper against the Bayer 4×4 threshold at `(x, y)`.

  ## Examples

      iex> alias RasterExRatatui.PixelFormat.Mono
      iex> Mono.rgb_pixel(255, 255, 255, 0, 0, %{})
      <<255>>
      iex> Mono.rgb_pixel(0, 0, 0, 3, 3, %{})
      <<0>>
      iex> for x <- 0..3, y <- 0..3, into: <<>>, do: Mono.rgb_pixel(128, 128, 128, x, y, %{})
      <<255, 0, 255, 0, 0, 255, 0, 255, 255, 0, 255, 0, 0, 255, 0, 255>>
  """
  @spec rgb_pixel(0..255, 0..255, 0..255, non_neg_integer(), non_neg_integer(), term()) ::
          binary()
  def rgb_pixel(r, g, b, x, y, _config) do
    threshold = @bayer |> elem(rem(y, 4)) |> elem(rem(x, 4)) |> Kernel.*(16) |> Kernel.+(8)
    if luma(r, g, b) < threshold, do: @ink, else: @paper
  end

  @impl true
  @doc """
  Dithers a row of RGB pixels against the Bayer row for `y`, walking the tile from `x`.

  ## Examples

      iex> alias RasterExRatatui.PixelFormat.Mono
      iex> Mono.rgb_row(:binary.copy(<<128, 128, 128>>, 4), 0, 1, %{})
      <<0, 255, 0, 255>>
      iex> Mono.rgb_row(:binary.copy(<<128, 128, 128>>, 4), 1, 1, %{})
      <<255, 0, 255, 0>>
  """
  @spec rgb_row(binary(), non_neg_integer(), non_neg_integer(), term()) :: binary()
  def rgb_row(row, x, y, _config) do
    thresholds = @bayer |> elem(rem(y, 4)) |> Tuple.to_list() |> Enum.map(&(&1 * 16 + 8))
    dither(row, rem(x, 4), List.to_tuple(thresholds), [])
  end

  defp dither(<<r, g, b, rest::binary>>, i, thresholds, acc) do
    tone = if luma(r, g, b) < elem(thresholds, i), do: @ink, else: @paper
    dither(rest, rem(i + 1, 4), thresholds, [tone | acc])
  end

  defp dither(<<>>, _i, _thresholds, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  @impl true
  @doc """
  Paper.

  ## Examples

      iex> RasterExRatatui.PixelFormat.Mono.blank(%{})
      <<255>>
  """
  @spec blank(term()) :: binary()
  def blank(_config), do: @paper

  defp bg_tone(:black, _config), do: @ink
  defp bg_tone({:rgb, r, g, b}, config), do: rgb_tone(r, g, b, config)
  defp bg_tone(_other, _config), do: @paper

  defp fg_tone(:black, _bg, _config), do: @ink
  defp fg_tone({:rgb, r, g, b}, _bg, config), do: rgb_tone(r, g, b, config)
  defp fg_tone(_reset_or_named, @ink, _config), do: @paper
  defp fg_tone(_reset_or_named, _bg, _config), do: @ink

  defp rgb_tone(r, g, b, %{ink_max: ink_max, paper_min: paper_min}) do
    case luma(r, g, b) do
      luma when luma <= ink_max -> @ink
      luma when luma >= paper_min -> @paper
      _luma -> @gray
    end
  end

  # Rec. 601 luma.
  defp luma(r, g, b), do: div(299 * r + 587 * g + 114 * b, 1000)
end
