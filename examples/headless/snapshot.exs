# Example: render a screen to pixels without any display.
#
# Draws a small dashboard (text, a gauge, a sparkline, and a 3D cube that
# arrives as a pixel region) into an ExRatatui.CellSession sized for a
# 640x360 panel, rasterises the diff twice, and writes both results as
# PNGs with Raster.to_png/1:
#
#   * a colour frame (XRGB8888 at scale 2)
#   * a 1-bit e-ink frame (Mono at scale 1)
#
#   mix run examples/headless/snapshot.exs
#   mix run examples/headless/snapshot.exs /tmp/snapshot

alias ExRatatui.CellSession
alias ExRatatui.Layout.Rect
alias ExRatatui.Style
alias ExRatatui.ThreeD.{Camera, Light, Material, Mesh, Object, Scene, Transform}
alias ExRatatui.Widgets.{Block, Gauge, Paragraph, Sparkline, Viewport3D}
alias RasterExRatatui.PixelFormat.{Mono, XRGB8888}
alias RasterExRatatui.Raster

defmodule Snapshot do
  def widgets({cols, rows}) do
    left = div(cols, 2)

    cube = %Viewport3D{
      scene: %Scene{
        objects: [
          %Object{
            mesh: Mesh.cube(),
            material: %Material{color: {120, 170, 255}},
            transform: %Transform{rotation: {:euler_xyz, {0.5, 0.8, 0.0}}}
          }
        ],
        lights: [
          Light.ambient({255, 255, 255}, 0.2),
          Light.directional({-1.0, -1.0, -1.0}, {255, 255, 255})
        ],
        background: {20, 20, 30}
      },
      camera: %Camera{position: {2.5, 2.0, 3.5}, target: {0.0, 0.0, 0.0}},
      render_mode: :auto,
      block: %Block{title: " cube ", borders: [:all]}
    }

    [
      {%Paragraph{
         text: "raster_ex_ratatui\n\nCells become glyphs,\nregions become pixels.",
         block: %Block{title: " hello ", borders: [:all], border_style: %Style{fg: :cyan}}
       }, %Rect{x: 0, y: 0, width: left, height: div(rows, 2)}},
      {%Gauge{
         ratio: 0.62,
         label: "62%",
         gauge_style: %Style{fg: :green},
         block: %Block{title: " load ", borders: [:all]}
       }, %Rect{x: 0, y: div(rows, 2), width: left, height: 3}},
      {%Sparkline{
         data: Enum.map(0..40, &round(8 + 7 * :math.sin(&1 / 3))),
         style: %Style{fg: :yellow},
         block: %Block{title: " signal ", borders: [:all]}
       }, %Rect{x: 0, y: div(rows, 2) + 3, width: left, height: rows - div(rows, 2) - 3}},
      {cube, %Rect{x: left, y: 0, width: cols - left, height: rows}}
    ]
  end

  def render(raster) do
    {cols, rows} = Raster.grid_size(raster)
    session = CellSession.new(cols, rows, font_size: Raster.font_size(raster))
    :ok = CellSession.draw(session, widgets({cols, rows}))
    diff = CellSession.take_cells_diff(session)
    :ok = CellSession.close(session)

    {raster, _patches} = Raster.apply(raster, diff)
    raster
  end
end

prefix = List.first(System.argv()) || Path.join(System.tmp_dir!(), "raster_ex_ratatui_snapshot")
size = {640, 360}

colour = Snapshot.render(Raster.new(size: size, format: XRGB8888, scale: 2))
File.write!("#{prefix}.png", Raster.to_png(colour))

mono = Snapshot.render(Raster.new(size: size, format: Mono))
File.write!("#{prefix}_mono.png", Raster.to_png(mono))

IO.puts("""
colour: #{inspect(Raster.grid_size(colour))} cells at #{inspect(Raster.font_size(colour))} px -> #{prefix}.png
mono:   #{inspect(Raster.grid_size(mono))} cells at #{inspect(Raster.font_size(mono))} px -> #{prefix}_mono.png
""")
