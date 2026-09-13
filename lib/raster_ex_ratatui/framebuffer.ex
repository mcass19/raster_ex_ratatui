defmodule RasterExRatatui.Framebuffer do
  @moduledoc """
  Writes packed pixels to a Linux framebuffer device (`/dev/fbN`).

  fbdev is the simplest way to put pixels on an HDMI monitor or a DSI panel from Elixir: the kernel exposes the display as a file, `/sys/class/graphics/fbN` describes its geometry, and writing bytes at the right offset lights the pixels. On a Raspberry Pi with the KMS driver the device comes from DRM's fbdev emulation.

      {:ok, fb} = Framebuffer.open("fb0")
      {:ok, format} = Framebuffer.format_for(fb.info)
      raster = Raster.new(size: {fb.info.width, fb.info.height}, format: format, scale: 3)
      # … on every push:
      :ok = Framebuffer.write(fb, patches)

  ## Stride

  A framebuffer line may be longer than `width * bytes_per_pixel` (the driver pads it to an alignment). Patches carry no padding, so `write/2` places every patch row at `y * stride + x * bytes_per_pixel`, and a full frame is written row by row when the stride differs from the visible line.

  ## Consoles

  The kernel's framebuffer console (fbcon) draws on the same device, so text and a blinking cursor can appear over the app. `unbind_console/2` detaches it; moving the system console off the display (a serial `ctty` on Nerves) keeps the boot log away too.

  ## Options

  Every function that touches the filesystem accepts `:root` (default `"/"`), prepended to `/sys/...` and `/dev/...`. It exists for tests and for devices that mount sysfs elsewhere.
  """

  alias RasterExRatatui.Patch
  alias RasterExRatatui.PixelFormat.{RGB565, XRGB8888}

  @typedoc "Framebuffer geometry, from sysfs."
  @type info :: %{
          width: pos_integer(),
          height: pos_integer(),
          bits_per_pixel: pos_integer(),
          stride: pos_integer()
        }

  @type t :: %__MODULE__{name: String.t(), device: :file.io_device(), info: info()}

  @enforce_keys [:name, :device, :info]
  defstruct [:name, :device, :info]

  @doc """
  Reads the geometry of framebuffer `name` (`"fb0"`) from `/sys/class/graphics/<name>`: `virtual_size`, `bits_per_pixel`, and `stride`.

  Returns `{:error, reason}` when a file is missing or does not hold what fbdev writes there.
  """
  @spec info(String.t(), keyword()) :: {:ok, info()} | {:error, term()}
  def info(name, opts \\ []) do
    dir = Path.join([root(opts), "sys/class/graphics", name])

    with {:ok, size} <- read(Path.join(dir, "virtual_size")),
         {:ok, bpp} <- read(Path.join(dir, "bits_per_pixel")),
         {:ok, stride} <- read(Path.join(dir, "stride")),
         [width, height] <- parse_integers(String.split(size, ",")),
         [bpp, stride] <- parse_integers([bpp, stride]) do
      {:ok, %{width: width, height: height, bits_per_pixel: bpp, stride: stride}}
    else
      {:error, reason} -> {:error, reason}
      _malformed -> {:error, {:malformed_sysfs, dir}}
    end
  end

  @doc """
  The pixel format for a framebuffer's depth: `RGB565` at 16 bits, `XRGB8888` at 32.

  ## Examples

      iex> RasterExRatatui.Framebuffer.format_for(%{bits_per_pixel: 32})
      {:ok, RasterExRatatui.PixelFormat.XRGB8888}

      iex> RasterExRatatui.Framebuffer.format_for(%{bits_per_pixel: 16})
      {:ok, RasterExRatatui.PixelFormat.RGB565}

      iex> RasterExRatatui.Framebuffer.format_for(%{bits_per_pixel: 24})
      {:error, :unsupported}
  """
  @spec format_for(%{bits_per_pixel: pos_integer()}) :: {:ok, module()} | {:error, :unsupported}
  def format_for(%{bits_per_pixel: 16}), do: {:ok, RGB565}
  def format_for(%{bits_per_pixel: 32}), do: {:ok, XRGB8888}
  def format_for(%{bits_per_pixel: _other}), do: {:error, :unsupported}

  @doc """
  Reads the geometry of framebuffer `name` and opens `/dev/<name>` for writing.
  """
  @spec open(String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def open(name, opts \\ []) do
    with {:ok, info} <- info(name, opts),
         {:ok, device} <-
           File.open(Path.join([root(opts), "dev", name]), [:write, :read, :raw, :binary]) do
      {:ok, %__MODULE__{name: name, device: device, info: info}}
    end
  end

  @doc """
  Writes a list of patches, or a `{:frame, binary}` covering the whole display, in one `:file.pwrite/2` call.
  """
  @spec write(t(), [Patch.t()] | {:frame, binary()}) :: :ok | {:error, term()}
  def write(%__MODULE__{device: device, info: info}, pixels) do
    :file.pwrite(device, locations(pixels, info, div(info.bits_per_pixel, 8)))
  end

  @doc """
  Closes the device.
  """
  @spec close(t()) :: :ok | {:error, term()}
  def close(%__MODULE__{device: device}), do: File.close(device)

  @doc """
  Blanks (`true`) or unblanks (`false`) the display through `/sys/class/graphics/<name>/blank`.
  """
  @spec blank(String.t(), boolean(), keyword()) :: :ok | {:error, term()}
  def blank(name, blank?, opts \\ []) when is_boolean(blank?) do
    path = Path.join([root(opts), "sys/class/graphics", name, "blank"])
    File.write(path, if(blank?, do: "1", else: "0"))
  end

  @doc """
  Detaches the kernel's framebuffer console so it stops drawing text and a cursor over the display.

  Writes `0` to `/sys/class/vtconsole/<console>/bind`. The framebuffer console is usually `"vtcon1"` (`"vtcon0"` is the dummy console); `/sys/class/vtconsole/*/name` tells them apart. Best effort: returns `{:error, reason}` when the kernel has no such console.
  """
  @spec unbind_console(String.t(), keyword()) :: :ok | {:error, term()}
  def unbind_console(console, opts \\ []) do
    File.write(Path.join([root(opts), "sys/class/vtconsole", console, "bind"]), "0")
  end

  defp locations({:frame, frame}, %{width: width, stride: stride}, bpp)
       when stride == width * bpp do
    [{0, frame}]
  end

  defp locations({:frame, frame}, %{width: width, height: height, stride: stride}, bpp) do
    line = width * bpp
    for y <- 0..(height - 1), do: {y * stride, binary_part(frame, y * line, line)}
  end

  defp locations(patches, %{stride: stride}, bpp) when is_list(patches) do
    for %Patch{} = patch <- patches, r <- 0..(patch.height - 1)//1 do
      span = patch.width * bpp
      {(patch.y + r) * stride + patch.x * bpp, binary_part(patch.data, r * span, span)}
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, String.trim(contents)}
      {:error, reason} -> {:error, {reason, path}}
    end
  end

  defp parse_integers(strings) do
    ints = for string <- strings, {n, ""} <- [Integer.parse(string)], n > 0, do: n
    if length(ints) == length(strings), do: ints, else: :error
  end

  defp root(opts), do: Keyword.get(opts, :root, "/")
end
