defmodule RasterExRatatui.Test.Frames do
  @moduledoc false

  alias ExRatatui.CellSession
  alias ExRatatui.CellSession.{Cell, Diff, Region}
  alias ExRatatui.Layout.Rect
  alias ExRatatui.ThreeD.{Camera, Light, Material, Mesh, Object, Scene}
  alias ExRatatui.Widgets.{Block, Viewport3D}
  alias RasterExRatatui.{Patch, Raster}

  @doc "Packed pixel at `(x, y)` of a full frame."
  def pixel(frame, %Raster{} = raster, x, y) do
    {width, _height} = Raster.size(raster)
    bpp = Raster.bytes_per_pixel(raster)
    binary_part(frame, (y * width + x) * bpp, bpp)
  end

  @doc "A full diff for a `cols × rows` grid with `cells` placed over blank cells."
  def full_diff({cols, rows}, cells, regions \\ []) do
    placed = Map.new(cells, &{{&1.col, &1.row}, &1})

    ops =
      for row <- 0..(rows - 1), col <- 0..(cols - 1) do
        Map.get(placed, {col, row}, %Cell{col: col, row: row})
      end

    %Diff{width: cols, height: rows, ops: ops, regions: regions}
  end

  @doc "A solid-colour region."
  def region(x, y, width, height, {r, g, b}, {pw, ph} \\ {1, 1}) do
    %Region{
      x: x,
      y: y,
      width: width,
      height: height,
      pixel_width: pw,
      pixel_height: ph,
      data: :binary.copy(<<r, g, b>>, pw * ph)
    }
  end

  @doc "Writes patches over a frame."
  def blit(frame, %Raster{} = raster, patches) do
    {width, _height} = Raster.size(raster)
    bpp = Raster.bytes_per_pixel(raster)
    Enum.reduce(patches, frame, &Patch.blit(&2, width, bpp, &1))
  end

  @doc "Draws widgets on a real session sized for the raster and returns its diff."
  def draw(%CellSession{} = session, widgets) do
    :ok = CellSession.draw(session, widgets)
    CellSession.take_cells_diff(session)
  end

  @doc "A session sized for the raster, with pixel regions on."
  def session(%Raster{} = raster) do
    {cols, rows} = Raster.grid_size(raster)
    CellSession.new(cols, rows, font_size: Raster.font_size(raster))
  end

  @doc "A lit cube in a bordered Viewport3D, which renders as a pixel region."
  def cube(%Rect{} = rect, angle \\ 0.8) do
    scene = %Scene{
      objects: [
        %Object{
          mesh: Mesh.cube(),
          material: %Material{color: {120, 170, 255}},
          transform: %ExRatatui.ThreeD.Transform{rotation: {:euler_xyz, {0.5, angle, 0.0}}}
        }
      ],
      lights: [
        Light.ambient({255, 255, 255}, 0.2),
        Light.directional({-1.0, -1.0, -1.0}, {255, 255, 255})
      ],
      background: {255, 255, 255}
    }

    viewport = %Viewport3D{
      scene: scene,
      camera: %Camera{position: {2.5, 2.0, 3.5}, target: {0.0, 0.0, 0.0}},
      render_mode: :auto,
      block: %Block{borders: [:all]}
    }

    {viewport, rect}
  end
end
