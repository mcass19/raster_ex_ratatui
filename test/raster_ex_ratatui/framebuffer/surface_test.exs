defmodule RasterExRatatui.Framebuffer.SurfaceTest.Panel do
  # Defined here rather than in test/support so the `use` macro expands
  # while coverage is recording.
  use RasterExRatatui.Framebuffer.Surface,
    app: RasterExRatatui.Test.App,
    input: RasterExRatatui.Test.Input
end

defmodule RasterExRatatui.Framebuffer.SurfaceTest.Counting do
  # Overrides that call the defaults and add to them.
  use RasterExRatatui.Framebuffer.Surface,
    app: RasterExRatatui.Test.App,
    input: RasterExRatatui.Test.Input,
    keyboard: false

  alias RasterExRatatui.Framebuffer.Surface, as: Default

  @impl true
  def init(opts) do
    {:ok, config, state} = Default.init(opts)
    {:ok, config, Map.merge(state, %{pushes: 0, test_pid: Keyword.fetch!(opts, :test_pid)})}
  end

  @impl true
  def push(pixels, state) do
    state = Default.push(pixels, state)
    send(state.test_pid, {:pushed, length(pixels)})
    %{state | pushes: state.pushes + 1}
  end

  @impl true
  def handle_info({:button, code}, state),
    do: {:events, [%ExRatatui.Event.Key{code: code, kind: "press"}], state}

  def handle_info(msg, state), do: Default.handle_info(msg, state)

  @impl true
  def terminate(reason, state) do
    send(state.test_pid, {:terminated, state.pushes})
    Default.terminate(reason, state)
  end
end

defmodule RasterExRatatui.Framebuffer.SurfaceTest do
  use ExUnit.Case, async: true

  alias ExRatatui.Event.{Key, Mouse}
  alias RasterExRatatui.Framebuffer.SurfaceTest.{Counting, Panel}
  alias RasterExRatatui.PixelFormat.{RGB565, XRGB8888}
  alias RasterExRatatui.{Raster, Surface}
  alias RasterExRatatui.Test.Input

  alias RasterExRatatui.Test.Panel, as: FakePanel

  @moduletag :tmp_dir
  @moduletag :capture_log

  @keyboard {"/dev/input/event1", %{report_info: [ev_key: [:key_esc, :key_a, :key_q]]}}

  setup %{tmp_dir: root} do
    Process.flag(:trap_exit, true)
    FakePanel.build(root, "360,320", 16, 720)
    Input.devices([@keyboard])
    %{root: root}
  end

  # A key press as input_event delivers it: one frame, no syn_report.
  defp press(code), do: [{:ev_key, code, 1}]

  defp eventually(fun, attempts \\ 50) do
    cond do
      fun.() -> true
      attempts > 0 -> Process.sleep(20) && eventually(fun, attempts - 1)
      true -> false
    end
  end

  describe "the panel" do
    test "is read from sysfs, painted, and its console detached", %{root: root} do
      surface =
        start_supervised!({Panel, root: root, keyboard: false, app_opts: [notify: self()]})

      assert_receive {:mounted, opts}

      assert %{size: {360, 320}, format: RGB565, scale: 1, grid_size: {60, 40}, rotate: 0} =
               opts[:surface]

      assert eventually(fn -> FakePanel.written(root) == 720 * 320 end)
      refute FakePanel.console_bound?(root)
      assert Raster.grid_size(Surface.raster(surface)) == {60, 40}
    end

    test "at 32 bits per pixel is XRGB8888, and scale and console can be set", %{root: root} do
      FakePanel.build(root, "1920,1080", 32, 7680)
      surface = start_supervised!({Panel, root: root, keyboard: false, scale: 4, console: false})

      raster = Surface.raster(surface)
      assert raster.format == XRGB8888
      assert Raster.font_size(raster) == {24, 32}
      assert FakePanel.console_bound?(root)
    end

    test "picks the scale for the long side, whichever way it is turned", %{root: root} do
      FakePanel.build(root, "720,1280", 16, 1440)
      surface = start_supervised!({Panel, root: root, keyboard: false, rotate: 90, columns: 50})

      # 1280 / (50 × 6) = 4: 24×32 pixel cells on a 1280×720 logical image.
      raster = Surface.raster(surface)
      assert raster.scale == 4
      assert Raster.grid_size(raster) == {53, 22}
    end

    test "turned by 90 writes inside the device", %{root: root} do
      surface =
        start_supervised!(
          {Panel, root: root, keyboard: false, rotate: 90, app_opts: [notify: self()]}
        )

      assert_receive {:mounted, opts}
      assert %{size: {360, 320}, grid_size: {53, 45}, rotate: 90} = opts[:surface]
      assert eventually(fn -> FakePanel.written(root) == 720 * 320 end)
      assert Raster.logical_size(Surface.raster(surface)) == {320, 360}
    end

    test "is waited for when its driver loads after the application", %{root: root} do
      FakePanel.remove(root)

      spawn_link(fn ->
        Process.sleep(400)
        FakePanel.build(root, "360,320", 16, 720)
      end)

      surface =
        start_supervised!({Panel, root: root, keyboard: false, framebuffer_timeout: 5_000})

      assert Raster.grid_size(Surface.raster(surface)) == {60, 40}
    end

    test "that never appears, or is too exotic, stops the surface at once", %{root: root} do
      FakePanel.remove(root)

      assert {:error, {:framebuffer, {:enoent, _path}}} =
               Panel.start_link(root: root, keyboard: false, framebuffer_timeout: 300)

      FakePanel.build(root, "360,320", 24, 1080)

      assert {:error, {:framebuffer, :unsupported}} =
               Panel.start_link(root: root, keyboard: false)
    end
  end

  describe "the keyboard" do
    test "is found, grabbed, and its keys reach the app", %{root: root} do
      surface = start_supervised!({Panel, root: root, app_opts: [notify: self()]})
      assert_receive {:mounted, _opts}
      assert_receive {:reader, reader, path: "/dev/input/event1", grab: true}
      assert eventually(fn -> FakePanel.written(root) == 720 * 320 end)

      send(surface, {:input_event, "/dev/input/event1", press(:key_a)})

      assert eventually(fn ->
               Raster.grid(Surface.raster(surface)).cells[{2, 0}].symbol == "a"
             end)

      # Unplugged: the reader is gone, the surface looks again and finds it.
      Process.exit(reader, :kill)
      assert_receive {:reader, again, _opts}, 1_000
      assert again != reader
      assert Process.alive?(surface)
    end

    test "quitting the app with q restarts it on the same surface", %{root: root} do
      surface = start_supervised!({Panel, root: root, app_opts: [notify: self()]})
      assert_receive {:mounted, _opts}
      assert_receive {:reader, _reader, _opts}
      first = Surface.server(surface)

      send(surface, {:input_event, "/dev/input/event1", press(:key_q)})

      assert_receive {:mounted, _opts}, 1_000
      assert Process.alive?(surface)
      assert Surface.server(surface) != first

      send(surface, {:input_event, "/dev/input/event1", press(:key_a)})

      assert eventually(fn ->
               Raster.grid(Surface.raster(surface)).cells[{2, 0}].symbol == "a"
             end)
    end

    test "is left to the supervisor with on_app_exit: :stop", %{root: root} do
      {:ok, surface} = Panel.start_link(root: root, on_app_exit: :stop)
      assert_receive {:reader, reader, _opts}

      send(surface, {:input_event, "/dev/input/event1", press(:key_q)})
      assert_receive {:EXIT, ^surface, :normal}
      assert_receive {:stopped, ^reader}
    end

    test "is not looked for without input_event, and the surface still runs", %{root: root} do
      surface = start_supervised!({Panel, root: root, input: No.Such.Module})

      refute_received {:reader, _reader, _opts}
      send(surface, :anything)
      assert eventually(fn -> FakePanel.written(root) == 720 * 320 end)
    end
  end

  describe "the touch panel" do
    @panel {"/dev/input/event2",
            %{
              report_info: [
                ev_key: [:btn_touch],
                ev_abs: [
                  abs_mt_slot: %{min: 0, max: 9},
                  abs_mt_tracking_id: %{min: 0, max: 65_535},
                  abs_mt_position_x: %{min: 0, max: 359},
                  abs_mt_position_y: %{min: 0, max: 319}
                ]
              ]
            }}

    # A tap as input_event delivers it: two messages, one frame each,
    # without the syn_report that ended the frame in the kernel.
    defp finger_tap(x, y) do
      [
        [
          {:ev_abs, :abs_mt_tracking_id, 4},
          {:ev_abs, :abs_mt_position_x, x},
          {:ev_abs, :abs_mt_position_y, y},
          {:ev_key, :btn_touch, 1},
          {:ev_abs, :abs_x, x},
          {:ev_abs, :abs_y, y}
        ],
        [{:ev_abs, :abs_mt_tracking_id, -1}, {:ev_key, :btn_touch, 0}]
      ]
    end

    test "lands taps in the app on the cell under the finger, flat and turned", %{root: root} do
      Input.devices([@keyboard, @panel])

      for {rotate, {px, py}, {col, row}} <- [{0, {13, 9}, {2, 1}}, {90, {5, 10}, {1, 44}}] do
        surface =
          start_supervised!(
            {Panel, root: root, touch: true, rotate: rotate, app_opts: [notify: self()]},
            id: {Panel, rotate}
          )

        assert_receive {:mounted, _opts}, 1_000
        assert_receive {:reader, _reader, path: "/dev/input/event2", grab: true}, 1_000

        for frame <- finger_tap(px, py),
            do: send(surface, {:input_event, "/dev/input/event2", frame})

        assert_receive {:mouse, %Mouse{kind: "down", button: "left", x: ^col, y: ^row}}, 1_000
        assert_receive {:mouse, %Mouse{kind: "up", x: ^col, y: ^row}}, 1_000

        :ok = stop_supervised({Panel, rotate})
      end
    end
  end

  describe "overrides" do
    test "can call the defaults and add to them", %{root: root} do
      surface = start_supervised!({Counting, root: root, test_pid: self()})

      assert_receive {:pushed, _patches}
      send(surface, {:button, "b"})
      assert_receive {:pushed, 1}

      assert eventually(fn ->
               Raster.grid(Surface.raster(surface)).cells[{2, 0}].symbol == "b"
             end)

      send(surface, :ignored)
      Surface.send_event(surface, %Key{code: "c", kind: "press"})
      assert_receive {:pushed, 1}

      :ok = stop_supervised(Counting)
      assert_receive {:terminated, 3}
    end
  end
end
