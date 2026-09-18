defmodule RasterExRatatui.Test.Panel do
  @moduledoc false

  # A fake Linux framebuffer under a `:root` directory: the sysfs files
  # `RasterExRatatui.Framebuffer.info/2` reads, the framebuffer console's
  # `bind` file, and an empty regular file standing in for `/dev/fb0`
  # (positioned writes grow it, so its size shows how far the surface wrote).

  @doc "Builds the tree; `size` is the `virtual_size` string, `\"360,320\"`."
  def build(root, size, bpp, stride, opts \\ []) do
    fb = Keyword.get(opts, :framebuffer, "fb0")
    console = Keyword.get(opts, :console, "vtcon1")
    graphics = Path.join([root, "sys/class/graphics", fb])
    vtconsole = Path.join([root, "sys/class/vtconsole", console])
    Enum.each([graphics, vtconsole, Path.join(root, "dev")], &File.mkdir_p!/1)

    File.write!(Path.join(graphics, "virtual_size"), size <> "\n")
    File.write!(Path.join(graphics, "bits_per_pixel"), "#{bpp}\n")
    File.write!(Path.join(graphics, "stride"), "#{stride}\n")
    File.write!(Path.join(vtconsole, "bind"), "1\n")
    File.write!(Path.join([root, "dev", fb]), "")
    :ok
  end

  @doc "Removes the tree, as if the driver never loaded."
  def remove(root, opts \\ []) do
    fb = Keyword.get(opts, :framebuffer, "fb0")
    File.rm_rf!(Path.join([root, "sys/class/graphics", fb]))
    File.rm_rf!(Path.join([root, "dev", fb]))
    :ok
  end

  @doc "The bytes written to the fake device so far."
  def written(root, opts \\ []) do
    fb = Keyword.get(opts, :framebuffer, "fb0")
    File.stat!(Path.join([root, "dev", fb])).size
  end

  @doc "What the console's bind file holds."
  def console_bound?(root, opts \\ []) do
    console = Keyword.get(opts, :console, "vtcon1")
    File.read!(Path.join([root, "sys/class/vtconsole", console, "bind"])) != "0"
  end
end
