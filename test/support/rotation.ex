defmodule RasterExRatatui.Test.Rotation do
  @moduledoc false

  # The reference the rotation tests compare against: the obvious, slow,
  # pixel-by-pixel rotation of a whole frame, from the corner mapping in the
  # `RasterExRatatui.Raster` moduledoc. The raster itself never rotates a
  # frame; it rotates glyph blocks, strips of cells, and region samples, and
  # this says what all of that must add up to.

  @doc "Rotates a `w × h` row-major frame of `bpp`-byte pixels clockwise by `angle`."
  def rotate_frame(frame, _w, _h, _bpp, 0), do: frame

  def rotate_frame(frame, w, h, bpp, angle) when angle in [90, 180, 270] do
    {out_w, out_h} = if angle == 180, do: {w, h}, else: {h, w}

    for py <- 0..(out_h - 1), px <- 0..(out_w - 1), into: <<>> do
      {x, y} = source(angle, px, py, w, h)
      binary_part(frame, (y * w + x) * bpp, bpp)
    end
  end

  # The logical pixel that lands on physical (px, py): the inverse of
  # 90: (x, y) → (W - 1 - y, x), 180: (W - 1 - x, H - 1 - y), 270: (y, H - 1 - x).
  defp source(90, px, py, _w, h), do: {py, h - 1 - px}
  defp source(180, px, py, w, h), do: {w - 1 - px, h - 1 - py}
  defp source(270, px, py, w, _h), do: {w - 1 - py, px}
end
