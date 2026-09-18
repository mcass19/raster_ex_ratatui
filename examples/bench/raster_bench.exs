# Rasterisation cost on a 1080p panel: a 106×45 grid of 18×24 cells
# (Default6x8 at scale 3) packed as XRGB8888.
#
#   mix run examples/bench/raster_bench.exs

alias ExRatatui.CellSession.{Cell, Diff, Region}
alias RasterExRatatui.PixelFormat.XRGB8888
alias RasterExRatatui.Raster

defmodule RasterBench do
  def measure(label, runs, fun) do
    fun.()

    micros =
      for _ <- 1..runs do
        {us, _} = :timer.tc(fun)
        us
      end
      |> Enum.sort()

    median = Enum.at(micros, div(runs, 2))

    IO.puts(
      String.pad_trailing(label, 44) <>
        "median #{Float.round(median / 1000, 1)} ms over #{runs} runs"
    )
  end

  def full_diff({cols, rows}, symbol_fun) do
    ops =
      for row <- 0..(rows - 1), col <- 0..(cols - 1) do
        %Cell{
          col: col,
          row: row,
          symbol: symbol_fun.(col, row),
          fg: Enum.at([:green, :reset, :yellow], rem(row, 3))
        }
      end

    %Diff{width: cols, height: rows, ops: ops}
  end
end

raster = Raster.new(size: {1920, 1080}, format: XRGB8888, scale: 3)
{cols, rows} = grid = Raster.grid_size(raster)
IO.puts("grid #{cols}x#{rows}, cell #{inspect(Raster.font_size(raster))}\n")

text = "The quick brown fox jumps over the lazy dog 0123456789 ─│┌┐└┘ █▀▄ ⠿⣿ "
symbol = fn col, row -> String.at(text, rem(col + row, String.length(text))) end
full = RasterBench.full_diff(grid, symbol)

RasterBench.measure("apply/2, full payload (cold cache)", 5, fn ->
  Raster.apply(Raster.new(size: {1920, 1080}, format: XRGB8888, scale: 3), full)
end)

RasterBench.measure("apply/2, full payload (warm cache)", 5, fn -> Raster.apply(raster, full) end)

{warm, _} = Raster.apply(raster, full)

RasterBench.measure("frame/1, full 1920x1080 buffer", 5, fn -> Raster.frame(warm) end)

ops =
  for i <- 0..49 do
    %Cell{col: rem(i * 7, cols), row: rem(i * 3, rows), symbol: "#", fg: :red}
  end

diff = %Diff{width: cols, height: rows, ops: ops}
RasterBench.measure("apply/2, 50 changed cells", 20, fn -> Raster.apply(warm, diff) end)

line = %Diff{
  width: cols,
  height: rows,
  ops: for(col <- 0..(cols - 1), do: %Cell{col: col, row: 10, symbol: "=", fg: :cyan})
}

RasterBench.measure("apply/2, one full row (106 cells)", 20, fn -> Raster.apply(warm, line) end)

for {w, h} <- [{20, 10}, {53, 22}] do
  {pw, ph} = {w * 18, h * 24}
  scale_down = max(1, max(ceil(pw / 1280), ceil(ph / 1280)))
  {pw, ph} = {div(pw, scale_down), div(ph, scale_down)}
  data = for y <- 0..(ph - 1), x <- 0..(pw - 1), into: <<>>, do: <<rem(x, 256), rem(y, 256), 128>>
  region = %Region{x: 2, y: 2, width: w, height: h, pixel_width: pw, pixel_height: ph, data: data}

  RasterBench.measure("apply/2, #{w}x#{h}-cell region (#{pw}x#{ph} px)", 10, fn ->
    Raster.apply(warm, %Diff{width: cols, height: rows, regions: [region]})
  end)
end

# A still image beside an animation: the big region stays the same from one
# payload to the next and only the small one changes, so only the small one
# is rasterised.
gradient = fn pw, ph, blue ->
  for y <- 0..(ph - 1), x <- 0..(pw - 1), into: <<>>, do: <<rem(x, 256), rem(y, 256), blue>>
end

still = %Region{
  x: 50,
  y: 2,
  width: 53,
  height: 22,
  pixel_width: 954,
  pixel_height: 528,
  data: gradient.(954, 528, 128)
}

turning = fn blue ->
  %Region{
    x: 2,
    y: 2,
    width: 20,
    height: 10,
    pixel_width: 360,
    pixel_height: 240,
    data: gradient.(360, 240, blue)
  }
end

[before, after_turn] = [turning.(0), turning.(255)]
{both, _} = Raster.apply(warm, %Diff{width: cols, height: rows, regions: [still, before]})

RasterBench.measure("apply/2, 20x10 region beside a still 53x22", 10, fn ->
  Raster.apply(both, %Diff{width: cols, height: rows, regions: [still, after_turn]})
end)

# Ten renders folded into one call, as the surface does when it has fallen
# behind: the region is rasterised once, in its final state.
turns =
  for blue <- 1..10, do: %Diff{width: cols, height: rows, regions: [still, turning.(blue * 20)]}

RasterBench.measure("apply/2, ten queued turns of that region as one list", 10, fn ->
  Raster.apply(both, turns)
end)

# The same panel on its side: a 1080x1920 framebuffer showing the app
# turned by 90. Same grid, same payloads; the cost should be about the same.
IO.puts("\nrotate: 90 (physical 1080x1920, logical 1920x1080)")
turned = Raster.new(size: {1080, 1920}, format: XRGB8888, scale: 3, rotate: 90)

RasterBench.measure("apply/2, full payload (cold cache)", 5, fn ->
  Raster.apply(Raster.new(size: {1080, 1920}, format: XRGB8888, scale: 3, rotate: 90), full)
end)

{turned, _} = Raster.apply(turned, full)
RasterBench.measure("apply/2, full payload (warm cache)", 5, fn -> Raster.apply(turned, full) end)
RasterBench.measure("frame/1, full 1080x1920 buffer", 5, fn -> Raster.frame(turned) end)
RasterBench.measure("apply/2, 50 changed cells", 20, fn -> Raster.apply(turned, diff) end)
RasterBench.measure("apply/2, one full row (106 cells)", 20, fn -> Raster.apply(turned, line) end)

{turned_both, _} =
  Raster.apply(turned, %Diff{width: cols, height: rows, regions: [still, before]})

RasterBench.measure("apply/2, 20x10 region beside a still 53x22", 10, fn ->
  Raster.apply(turned_both, %Diff{width: cols, height: rows, regions: [still, after_turn]})
end)

RasterBench.measure("apply/2, 53x22-cell region (954x528 px)", 10, fn ->
  Raster.apply(turned, %Diff{width: cols, height: rows, regions: [still]})
end)
