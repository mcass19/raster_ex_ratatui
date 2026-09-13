defmodule RasterExRatatui.FramebufferTest do
  use ExUnit.Case, async: true

  alias RasterExRatatui.{Framebuffer, Patch}

  doctest Framebuffer

  @moduletag :tmp_dir

  defp fake_fb(root, {width, height}, bpp, stride) do
    sysfs = Path.join(root, "sys/class/graphics/fb0")
    File.mkdir_p!(sysfs)
    File.mkdir_p!(Path.join(root, "dev"))
    File.write!(Path.join(sysfs, "virtual_size"), "#{width},#{height}\n")
    File.write!(Path.join(sysfs, "bits_per_pixel"), "#{bpp}\n")
    File.write!(Path.join(sysfs, "stride"), "#{stride}\n")
    File.write!(Path.join(sysfs, "blank"), "")
    File.write!(Path.join(root, "dev/fb0"), :binary.copy(<<0>>, stride * height))
  end

  defp device(root), do: File.read!(Path.join(root, "dev/fb0"))

  describe "info/2" do
    test "reads the geometry from sysfs", %{tmp_dir: root} do
      fake_fb(root, {1920, 1080}, 32, 7680)

      assert Framebuffer.info("fb0", root: root) ==
               {:ok, %{width: 1920, height: 1080, bits_per_pixel: 32, stride: 7680}}
    end

    test "reports a missing framebuffer", %{tmp_dir: root} do
      assert {:error, {:enoent, path}} = Framebuffer.info("fb3", root: root)
      assert path =~ "fb3/virtual_size"
    end

    test "reports malformed sysfs contents", %{tmp_dir: root} do
      fake_fb(root, {1920, 1080}, 32, 7680)
      File.write!(Path.join(root, "sys/class/graphics/fb0/virtual_size"), "1920\n")
      assert {:error, {:malformed_sysfs, _}} = Framebuffer.info("fb0", root: root)

      File.write!(Path.join(root, "sys/class/graphics/fb0/virtual_size"), "1920,1080\n")
      File.write!(Path.join(root, "sys/class/graphics/fb0/stride"), "wide\n")
      assert {:error, {:malformed_sysfs, _}} = Framebuffer.info("fb0", root: root)
    end
  end

  describe "open/2 and write/2" do
    test "writes each patch row at y * stride + x * bpp", %{tmp_dir: root} do
      # 4 px wide, 16 bpp, but lines padded to 10 bytes.
      fake_fb(root, {4, 3}, 16, 10)
      {:ok, fb} = Framebuffer.open("fb0", root: root)

      patch = %Patch{x: 1, y: 1, width: 2, height: 2, data: <<1, 1, 2, 2, 3, 3, 4, 4>>}
      assert :ok = Framebuffer.write(fb, [patch])
      assert :ok = Framebuffer.close(fb)

      assert device(root) ==
               <<0::80, 0, 0, 1, 1, 2, 2, 0, 0, 0, 0, 0, 0, 3, 3, 4, 4, 0, 0, 0, 0>>
    end

    test "writes a frame in one piece when there is no line padding", %{tmp_dir: root} do
      fake_fb(root, {2, 2}, 32, 8)
      {:ok, fb} = Framebuffer.open("fb0", root: root)
      frame = for i <- 1..16, into: <<>>, do: <<i>>

      assert :ok = Framebuffer.write(fb, {:frame, frame})
      assert device(root) == frame
    end

    test "writes a frame row by row when lines are padded", %{tmp_dir: root} do
      fake_fb(root, {2, 2}, 16, 6)
      {:ok, fb} = Framebuffer.open("fb0", root: root)

      assert :ok = Framebuffer.write(fb, {:frame, <<1, 2, 3, 4, 5, 6, 7, 8>>})
      assert device(root) == <<1, 2, 3, 4, 0, 0, 5, 6, 7, 8, 0, 0>>
    end

    test "fails when the device node is missing", %{tmp_dir: root} do
      fake_fb(root, {2, 2}, 32, 8)
      File.rm!(Path.join(root, "dev/fb0"))
      File.mkdir_p!(Path.join(root, "dev/fb0"))

      assert {:error, :eisdir} = Framebuffer.open("fb0", root: root)
    end
  end

  describe "without :root" do
    # A device name that exists on no machine, so the real /sys is only read, never changed.
    @missing "fb-raster-ex-ratatui-test"

    test "functions default to the real sysfs and /dev" do
      assert {:error, {:enoent, "/sys/class/graphics/" <> _}} = Framebuffer.info(@missing)
      assert {:error, {:enoent, _}} = Framebuffer.open(@missing)
      assert {:error, _} = Framebuffer.blank(@missing, true)
      assert {:error, _} = Framebuffer.unbind_console("vtcon-raster-ex-ratatui-test")
    end
  end

  describe "blank/3 and unbind_console/2" do
    test "write the sysfs switches", %{tmp_dir: root} do
      fake_fb(root, {2, 2}, 32, 8)
      console = Path.join(root, "sys/class/vtconsole/vtcon1")
      File.mkdir_p!(console)

      assert :ok = Framebuffer.blank("fb0", true, root: root)
      assert File.read!(Path.join(root, "sys/class/graphics/fb0/blank")) == "1"
      assert :ok = Framebuffer.blank("fb0", false, root: root)
      assert File.read!(Path.join(root, "sys/class/graphics/fb0/blank")) == "0"

      assert :ok = Framebuffer.unbind_console("vtcon1", root: root)
      assert File.read!(Path.join(console, "bind")) == "0"
      assert {:error, :enoent} = Framebuffer.unbind_console("vtcon9", root: root)
    end
  end
end
