defmodule RpiFramebuffer.SurfaceTest do
  use ExUnit.Case, async: true

  alias RasterExRatatui.Raster
  alias RpiFramebuffer.Surface

  @moduletag :tmp_dir
  @moduletag :capture_log

  # A fake 720×1280 16-bit panel: the sysfs files the library reads, the
  # framebuffer console's bind file, and an empty file for /dev/fb0.
  setup %{tmp_dir: root} do
    graphics = Path.join(root, "sys/class/graphics/fb0")
    console = Path.join(root, "sys/class/vtconsole/vtcon1")
    Enum.each([graphics, console, Path.join(root, "dev")], &File.mkdir_p!/1)
    File.write!(Path.join(graphics, "virtual_size"), "720,1280\n")
    File.write!(Path.join(graphics, "bits_per_pixel"), "16\n")
    File.write!(Path.join(graphics, "stride"), "1440\n")
    File.write!(Path.join(console, "bind"), "1")
    File.write!(Path.join(root, "dev/fb0"), "")
    %{root: root}
  end

  defp written(root), do: File.stat!(Path.join(root, "dev/fb0")).size

  defp eventually(check, attempts \\ 100) do
    cond do
      check.() -> true
      attempts == 0 -> false
      true -> Process.sleep(20) && eventually(check, attempts - 1)
    end
  end

  test "puts the dashboard on the panel, turned as configured", %{root: root} do
    surface = start_supervised!({Surface, root: root, keyboard: false, rotate: 90})
    raster = RasterExRatatui.Surface.raster(surface)

    assert Raster.size(raster) == {720, 1280}
    assert Raster.grid_size(raster) == {106, 45}
    assert raster.format == RasterExRatatui.PixelFormat.RGB565
    assert eventually(fn -> written(root) == 1440 * 1280 end)
    assert File.read!(Path.join(root, "sys/class/vtconsole/vtcon1/bind")) == "0"
  end

  test "passes the dashboard its options", %{root: root} do
    surface = start_supervised!({Surface, root: root, keyboard: false, app_opts: [spin_ms: 50]})
    server = RasterExRatatui.Surface.server(surface)

    assert %{subscription_count: 2} = ExRatatui.Runtime.snapshot(server)
    assert eventually(fn -> written(root) == 1440 * 1280 end)
  end
end
