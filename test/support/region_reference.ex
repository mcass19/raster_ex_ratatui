defmodule RasterExRatatui.Test.RegionReference do
  @moduledoc false

  # The region path as the raster ran it in Elixir before packing went
  # native, kept as the oracle the native path must match byte for byte:
  # sample the bitmap onto its rect against the *full* rect (so a region
  # clipped at the grid edge samples as if whole), turn it with the corner
  # mapping, then pack every pixel with the format's `rgb_pixel/6` at its
  # panel position.

  alias ExRatatui.CellSession.Region
  alias RasterExRatatui.{Patch, Raster}
  alias RasterExRatatui.Test.Rotation

  @doc "The patch `region` paints on `raster`, or `nil` when it is wholly off the grid."
  def patch(%Raster{} = raster, %Region{} = region) do
    {cell_w, cell_h} = raster.cell_size
    {cols, rows} = raster.grid_size
    {x0, y0} = {region.x * cell_w, region.y * cell_h}
    full = {region.width * cell_w, region.height * cell_h}
    rect_w = min(elem(full, 0), cols * cell_w - x0)
    rect_h = min(elem(full, 1), rows * cell_h - y0)

    if rect_w > 0 and rect_h > 0 do
      turned =
        region
        |> sample(full, rect_w, rect_h)
        |> Rotation.rotate_frame(rect_w, rect_h, 3, raster.rotate)

      {x, y, width, height} = physical_rect(raster, {x0, y0, rect_w, rect_h})
      data = pack(raster, turned, x, y, width)
      %Patch{x: x, y: y, width: width, height: height, data: data}
    end
  end

  # `rect_w × rect_h` RGB8 in the app's orientation, nearest-neighbour from
  # the bitmap stretched over the full `{full_w, full_h}` rect.
  defp sample(%Region{pixel_width: pw, pixel_height: ph, data: data}, {full_w, full_h}, w, h) do
    for dy <- 0..(h - 1), dx <- 0..(w - 1), into: <<>> do
      {sx, sy} = {div(dx * pw, full_w), div(dy * ph, full_h)}
      binary_part(data, (sy * pw + sx) * 3, 3)
    end
  end

  # Every pixel through `rgb_pixel/6` at its panel position.
  defp pack(%Raster{format: format, config: config}, rgb, x, y, width) do
    pixels = for <<pixel::binary-3 <- rgb>>, do: pixel

    for {<<r, g, b>>, i} <- Enum.with_index(pixels), into: <<>> do
      format.rgb_pixel(r, g, b, x + rem(i, width), y + div(i, width), config)
    end
  end

  defp physical_rect(%Raster{rotate: 0}, rect), do: rect
  defp physical_rect(%Raster{rotate: 90, size: {pw, _}}, {x, y, w, h}), do: {pw - y - h, x, h, w}

  defp physical_rect(%Raster{rotate: 180, size: {pw, ph}}, {x, y, w, h}),
    do: {pw - x - w, ph - y - h, w, h}

  defp physical_rect(%Raster{rotate: 270, size: {_, ph}}, {x, y, w, h}), do: {y, ph - x - w, h, w}
end
