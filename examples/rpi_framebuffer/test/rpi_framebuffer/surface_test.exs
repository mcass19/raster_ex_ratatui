defmodule RpiFramebuffer.SurfaceTest do
  # Not async: the input stub is one named agent.
  use ExUnit.Case, async: false

  alias RasterExRatatui.PixelFormat.RGB565
  alias RasterExRatatui.PixelFormat.XRGB8888
  alias RasterExRatatui.Raster
  alias RpiFramebuffer.Surface

  doctest Surface

  @moduletag :tmp_dir
  @moduletag :capture_log

  defmodule Input do
    @moduledoc false
    # Stands in for InputEvent: devices come from an agent, and every call is reported to the test.

    def start(test, devices), do: Agent.start_link(fn -> {test, devices} end, name: __MODULE__)
    def put_devices(devices), do: Agent.update(__MODULE__, fn {test, _old} -> {test, devices} end)

    def enumerate do
      {test, devices} = Agent.get(__MODULE__, & &1)
      send(test, :enumerated)
      devices
    end

    def start_link(opts) do
      {test, _devices} = Agent.get(__MODULE__, & &1)
      reader = spawn_link(fn -> Process.sleep(:infinity) end)
      send(test, {:reader, reader, opts})
      {:ok, reader}
    end
  end

  @keyboard {"/dev/input/event1", %{report_info: [ev_key: [:key_esc, :key_a, :key_tab]]}}
  @touch {"/dev/input/event0", %{report_info: [ev_key: [:btn_touch]]}}

  setup %{tmp_dir: root} do
    panel(root, "360,320", 16, 720)
    %{root: root}
  end

  describe "the panel" do
    test "is read from sysfs: size, depth, and a scale to match", %{root: root} do
      surface = start_supervised!({Surface, root: root, keyboard: false})
      raster = RasterExRatatui.Surface.raster(surface)

      assert Raster.size(raster) == {360, 320}
      assert Raster.grid_size(raster) == {60, 40}
      assert raster.format == RGB565
    end

    test "gets the dashboard's pixels and loses its console", %{root: root} do
      start_supervised!({Surface, root: root, keyboard: false})

      assert eventually(fn -> File.stat!(Path.join(root, "dev/fb0")).size == 720 * 320 end)
      assert File.read!(Path.join(root, "sys/class/vtconsole/vtcon1/bind")) == "0"
    end

    test "at 32 bits per pixel is XRGB8888, and the scale can be forced", %{root: root} do
      panel(root, "360,320", 32, 1440)
      surface = start_supervised!({Surface, root: root, keyboard: false, scale: 2})
      raster = RasterExRatatui.Surface.raster(surface)

      assert raster.format == XRGB8888
      assert Raster.grid_size(raster) == {30, 20}
    end

    test "that is missing or too exotic stops the surface", %{root: root} do
      Process.flag(:trap_exit, true)

      assert {:error, {:framebuffer, {:enoent, _path}}} =
               Surface.start_link(root: root, framebuffer: "fb7", keyboard: false)

      panel(root, "360,320", 24, 1080)

      assert {:error, {:framebuffer, :unsupported}} =
               Surface.start_link(root: root, keyboard: false)
    end

    test "survives a kernel without that console", %{root: root} do
      surface = start_supervised!({Surface, root: root, keyboard: false, console: "vtcon9"})
      assert Process.alive?(surface)
    end
  end

  describe "the keyboard" do
    setup do
      start_supervised!(%{id: Input, start: {Input, :start, [self(), [@touch, @keyboard]]}})
      :ok
    end

    test "is the first device with letter keys, grabbed", %{root: root} do
      start_supervised!({Surface, root: root, input: Input})

      assert_receive :enumerated
      assert_receive {:reader, _reader, path: "/dev/input/event1", grab: true}
    end

    test "reaches the dashboard as key events, modifiers included", %{root: root} do
      handler = "surface-test-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:raster_ex_ratatui, :input, :forward],
        &__MODULE__.forwarded/4,
        self()
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      surface = start_supervised!({Surface, root: root, input: Input})
      assert_receive {:reader, _reader, _opts}

      events = [{:ev_key, :key_leftshift, 1}, {:ev_key, :key_a, 1}, {:ev_key, :key_a, 0}]
      send(surface, {:input_event, "/dev/input/event1", events})

      assert_receive {:forwarded,
                      %ExRatatui.Event.Key{code: "A", kind: "press", modifiers: ["shift"]}}
    end

    test "is looked for again when it goes away", %{root: root} do
      start_supervised!({Surface, root: root, input: Input})
      assert_receive {:reader, reader, _opts}

      Process.exit(reader, :kill)

      assert_receive {:reader, other, path: "/dev/input/event1", grab: true}
      assert other != reader
    end

    test "is awaited when there is none", %{root: root} do
      Input.put_devices([@touch])
      surface = start_supervised!({Surface, root: root, input: Input})

      assert_receive :enumerated
      refute_receive {:reader, _reader, _opts}, 50

      Input.put_devices([@touch, @keyboard])
      send(surface, :find_keyboard)
      assert_receive {:reader, _reader, _opts}
    end

    test "is left alone with keyboard: false, and stray messages are ignored", %{root: root} do
      surface = start_supervised!({Surface, root: root, input: Input, keyboard: false})

      send(surface, :anything)
      refute_receive :enumerated, 50
      assert Process.alive?(surface)
    end
  end

  @doc false
  def forwarded(_event, _measurements, meta, test), do: send(test, {:forwarded, meta.event})

  defp panel(root, size, bpp, stride) do
    graphics = Path.join(root, "sys/class/graphics/fb0")
    console = Path.join(root, "sys/class/vtconsole/vtcon1")
    Enum.each([graphics, console, Path.join(root, "dev")], &File.mkdir_p!/1)

    File.write!(Path.join(graphics, "virtual_size"), "#{size}\n")
    File.write!(Path.join(graphics, "bits_per_pixel"), "#{bpp}\n")
    File.write!(Path.join(graphics, "stride"), "#{stride}\n")
    File.write!(Path.join(console, "bind"), "1")
    File.write!(Path.join(root, "dev/fb0"), "")
  end

  defp eventually(check, attempts \\ 100) do
    cond do
      check.() -> true
      attempts == 0 -> false
      true -> Process.sleep(10) && eventually(check, attempts - 1)
    end
  end
end
