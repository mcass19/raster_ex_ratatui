defmodule RasterExRatatui.SurfaceTest.DefaultSurface do
  # Defined here rather than in test/support so the `use` macro expands
  # while coverage is recording.
  use RasterExRatatui.Surface,
    app: RasterExRatatui.Test.App,
    format: RasterExRatatui.PixelFormat.XRGB8888,
    size: {60, 40}

  @impl true
  def push(pixels, opts) do
    send(Keyword.fetch!(opts, :test_pid), {:pushed, pixels})
    opts
  end
end

defmodule RasterExRatatui.SurfaceTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ExRatatui.CellSession.{Cell, Diff}
  alias ExRatatui.Event.Key
  alias RasterExRatatui.{Patch, Raster, Surface}
  alias RasterExRatatui.SurfaceTest.DefaultSurface
  alias RasterExRatatui.Test.FailingApp
  alias RasterExRatatui.Test.Surface, as: TestSurface

  defp start_surface(opts \\ []) do
    {:ok, surface} = TestSurface.start_link(Keyword.put_new(opts, :test_pid, self()))
    assert_receive {:pushed, _initial}
    surface
  end

  defp key(code), do: %Key{code: code, kind: "press"}

  defp pushed_area(patches), do: Enum.sum(Enum.map(patches, &(&1.width * &1.height)))

  defp frame(surface), do: surface |> Surface.raster() |> Raster.frame()

  # Every push that arrives until the surface has been quiet for `quiet` ms.
  defp collect_pushes(quiet) do
    receive do
      {:pushed, pixels} -> [pixels | collect_pushes(quiet)]
    after
      quiet -> []
    end
  end

  defp blit_all(frame, pushes, width, bpp) do
    pushes |> Enum.concat() |> Enum.reduce(frame, &Patch.blit(&2, width, bpp, &1))
  end

  describe "start" do
    test "the first render pushes the whole panel" do
      {:ok, surface} = TestSurface.start_link(test_pid: self())

      assert_receive {:pushed, patches}
      assert pushed_area(patches) == 240 * 160
      assert Raster.grid_size(Surface.raster(surface)) == {40, 20}
    end

    test "init/1 can abort the start" do
      Process.flag(:trap_exit, true)

      assert {:error, :no_device} =
               TestSurface.start_link(test_pid: self(), init_stop: :no_device)
    end

    test "an app that fails to mount stops the surface" do
      Process.flag(:trap_exit, true)
      assert {:error, :no_mount} = TestSurface.start_link(test_pid: self(), app: FailingApp)
    end

    test "invalid push_mode, min_interval, shutdown_timeout, and on_app_exit are rejected" do
      Process.flag(:trap_exit, true)

      invalid = [
        push_mode: :bytes,
        min_interval: :soon,
        shutdown_timeout: -1,
        on_app_exit: :retry
      ]

      for {key, value} <- invalid do
        capture_log(fn ->
          assert {:error, {%ArgumentError{message: message}, _}} =
                   TestSurface.start_link([{key, value}, test_pid: self()])

          assert message =~ inspect(key)
        end)
      end
    end

    test "an init/1 that returns something else is an ArgumentError naming it" do
      Process.flag(:trap_exit, true)

      capture_log(fn ->
        assert {:error, {%ArgumentError{message: message}, _}} =
                 TestSurface.start_link(test_pid: self(), init_return: {:ok, :state})

        assert message =~ "RasterExRatatui.Test.Surface.init/1"
        assert message =~ "{:ok, :state}"
      end)
    end

    test "app_opts reach the app and name registers the surface" do
      name = :"surface_#{System.unique_integer([:positive])}"
      start_surface(name: name, app_opts: [text: "hello"])

      frame = name |> Surface.raster() |> Raster.frame()
      blank = :binary.copy(<<255>>, 30 * 8)
      refute binary_part(frame, 0, 30 * 8) == blank
      assert is_pid(Surface.server(name))
    end

    test "the app sees the panel as surface: in its options" do
      start_surface(scale: 2, app_opts: [notify: self()])

      assert_receive {:mounted, opts}

      assert opts[:surface] == %{
               size: {240, 160},
               cell_size: {12, 16},
               grid_size: {20, 10},
               format: RasterExRatatui.PixelFormat.Mono,
               scale: 2,
               rotate: 0
             }

      assert opts[:width] == 20
      assert opts[:transport] == :cell_session
    end

    test "rotate: turns the grid and keeps the pushes inside the physical panel" do
      surface = start_surface(size: {160, 240}, rotate: 270, app_opts: [notify: self()])

      assert_receive {:mounted, opts}
      assert %{size: {160, 240}, grid_size: {40, 20}, rotate: 270} = opts[:surface]
      assert Raster.grid_size(Surface.raster(surface)) == {40, 20}

      Surface.send_event(surface, key("a"))
      # The third cell of the top row, (12, 0, 6, 8) to the app: at 270 the
      # app's top edge is the panel's left edge, and its x runs up the panel.
      assert_receive {:pushed, [%Patch{x: 0, y: 222, width: 8, height: 6}]}
    end

    test "use defaults: child_spec, init/1 returning the options, handle_info/2, terminate/2" do
      surface = start_supervised!({DefaultSurface, test_pid: self()})

      assert_receive {:pushed, [%Patch{} | _] = patches}
      assert pushed_area(patches) == 60 * 40

      send(surface, :ignored)
      Surface.send_event(surface, key("x"))
      assert_receive {:pushed, [%Patch{x: 12, y: 0, width: 6, height: 8}]}

      assert :ok = stop_supervised(DefaultSurface)
      assert DefaultSurface.child_spec([]).restart == :transient

      # The supervisor waits a second longer than the surface waits for the app.
      assert DefaultSurface.child_spec([]).shutdown == 5_000
      assert DefaultSurface.child_spec(shutdown_timeout: 9_000).shutdown == 10_000
    end
  end

  describe "rendering" do
    test "send_event/2 forwards keys and the next push holds only what changed" do
      surface = start_surface()
      Surface.send_event(surface, key("a"))

      assert_receive {:pushed, [%Patch{x: 12, y: 0, width: 6, height: 8, data: data}]}
      assert byte_size(data) == 48
    end

    test "a render that changes nothing pushes nothing" do
      surface = start_surface()
      send(Surface.server(surface), :unrelated)

      refute_receive {:pushed, _}, 100
    end

    test "handle_info/2 can return events for the app" do
      surface = start_surface()
      before = frame(surface)
      send(surface, {:keys, ["a", "b"]})

      pushes = collect_pushes(150)
      assert pushes != []
      assert pushes |> Enum.concat() |> Enum.map(&(&1.x + &1.width)) |> Enum.max() == 24
      assert blit_all(before, pushes, 240, 1) == frame(surface)
    end

    test "renders that arrive during a slow push are pushed together" do
      surface = start_surface(push_delay: 150)
      before = frame(surface)

      for code <- ~w(a b c d e), do: Surface.send_event(surface, key(code))

      pushes = collect_pushes(400)
      assert length(pushes) in 1..2
      assert blit_all(before, pushes, 240, 1) == frame(surface)
    end

    test "a render for another session and a flush with nothing pending are ignored" do
      surface = start_surface()
      stray = %Diff{width: 40, height: 20, ops: [%Cell{symbol: "x"}]}

      send(surface, {RasterExRatatui.Session, make_ref(), stray})
      send(surface, {RasterExRatatui.Surface.Server, :flush})

      refute_receive {:pushed, _}, 100
      assert Surface.raster(surface).grid.width == 40
    end

    test "renders queued behind a slow push are rasterised as one" do
      id = "surface-batch-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        id,
        [:raster_ex_ratatui, :frame, :raster, :stop],
        &__MODULE__.forward_event/4,
        self()
      )

      on_exit(fn -> :telemetry.detach(id) end)

      surface = start_surface(push_delay: 150)
      assert_receive {:telemetry, _, %{pid: ^surface, diffs: 1}}
      before = frame(surface)

      for code <- ~w(a b c d e), do: Surface.send_event(surface, key(code))
      pushes = collect_pushes(400)

      batches = for {:telemetry, _, %{pid: ^surface, diffs: n}} <- flush_mailbox(), do: n
      assert Enum.sum(batches) == 5
      assert Enum.max(batches) > 1
      assert length(pushes) == length(batches)
      assert blit_all(before, pushes, 240, 1) == frame(surface)
    end

    test "push_mode: :frame pushes whole panels" do
      surface = start_surface(push_mode: :frame)
      Surface.send_event(surface, key("a"))

      assert_receive {:pushed, {:frame, frame}}
      assert byte_size(frame) == 240 * 160
      assert frame == Raster.frame(Surface.raster(surface))
    end

    test "min_interval coalesces renders into one push" do
      surface = start_surface(min_interval: 150)
      Surface.send_event(surface, key("a"))
      Surface.send_event(surface, key("b"))

      assert_receive {:pushed, patches}, 1_000
      refute_receive {:pushed, _}, 300

      frame = Raster.frame(Surface.raster(surface))
      assert Enum.reduce(patches, frame, &Patch.blit(&2, 240, 1, &1)) == frame
      assert pushed_area(patches) >= 2 * 48
    end

    test "a Viewport3D in the app arrives as a region patch" do
      {:ok, _surface} = TestSurface.start_link(test_pid: self(), app_opts: [cube: true])

      assert_receive {:pushed, patches}

      assert Enum.any?(patches, &match?(%Patch{x: 6, y: 16, width: 60, height: 32}, &1))
    end

    test "resize/2 rebuilds the grid and repaints the new panel" do
      surface = start_surface()
      assert Surface.resize(surface, {120, 80}) == {20, 10}

      assert_receive {:pushed, patches}
      assert pushed_area(patches) == 120 * 80
      assert Raster.size(Surface.raster(surface)) == {120, 80}
    end
  end

  describe "exits" do
    test "an app crash stops the surface with the same reason" do
      Process.flag(:trap_exit, true)
      surface = start_surface()

      log =
        capture_log(fn ->
          Surface.send_event(surface, key("!"))
          assert_receive {:EXIT, ^surface, {%RuntimeError{message: "boom"}, _stack}}, 1_000
        end)

      assert log =~ "boom"
      assert_receive {:terminated, {%RuntimeError{}, _}}
    end

    test "an app that stops stops the surface normally" do
      Process.flag(:trap_exit, true)
      attach([[:raster_ex_ratatui, :app, :exit]])
      surface = start_surface()

      Surface.send_event(surface, key("q"))
      assert_receive {:EXIT, ^surface, :normal}
      assert_receive {:terminated, :normal}

      assert_receive {:telemetry, [_, :app, :exit],
                      %{pid: ^surface, reason: :normal, action: :stop}}
    end

    test "on_app_exit: :restart starts the app again when it stops, on the same surface" do
      attach([[:raster_ex_ratatui, :app, :exit]])
      surface = start_surface(on_app_exit: :restart, app_opts: [notify: self()])
      assert_receive {:mounted, _opts}
      first = Surface.server(surface)

      log =
        capture_log(fn ->
          Surface.send_event(surface, key("q"))
          assert_receive {:mounted, opts}
          assert opts[:surface].grid_size == {40, 20}
        end)

      assert_receive {:pushed, patches}
      assert pushed_area(patches) == 240 * 160

      assert_receive {:telemetry, [_, :app, :exit],
                      %{pid: ^surface, reason: :normal, action: :restart}}

      assert log =~ "starting it again"
      assert Process.alive?(surface)
      assert Surface.server(surface) != first
      refute Process.alive?(first)
    end

    test "on_app_exit: :restart starts the app again when it crashes" do
      Process.flag(:trap_exit, true)
      surface = start_surface(on_app_exit: :restart, app_opts: [notify: self()])
      assert_receive {:mounted, _opts}
      first = Surface.server(surface)

      capture_log(fn ->
        Surface.send_event(surface, key("!"))
        assert_receive {:mounted, _opts}, 1_000
      end)

      assert_receive {:pushed, patches}
      assert pushed_area(patches) == 240 * 160
      refute_received {:EXIT, ^surface, _reason}
      assert Surface.server(surface) != first

      Surface.send_event(surface, key("a"))
      assert_receive {:pushed, [%Patch{x: 12, y: 0, width: 6, height: 8}]}
    end

    test "on_app_exit: :restart gives up on a crash loop and stops with the app's reason" do
      Process.flag(:trap_exit, true)
      attach([[:raster_ex_ratatui, :app, :exit]])

      log =
        capture_log(fn ->
          {:ok, surface} =
            TestSurface.start_link(
              test_pid: self(),
              on_app_exit: :restart,
              max_restarts: 2,
              app_opts: [crash_loop: true]
            )

          assert_receive {:EXIT, ^surface, {%RuntimeError{message: "crash loop"}, _stack}}, 2_000
          send(self(), {:surface, surface})
        end)

      assert_received {:surface, surface}

      actions = for {:telemetry, _, %{pid: ^surface, action: a}} <- flush_mailbox(), do: a
      assert actions == [:restart, :restart, :stop]
      assert log =~ "crashed 3 times in 5 s, stopping the surface"
    end

    test "on_app_exit: :restart never counts quits against the limit" do
      surface = start_surface(on_app_exit: :restart, max_restarts: 0, app_opts: [notify: self()])
      assert_receive {:mounted, _opts}

      # A plain quit exits :normal; "Q" exits {:shutdown, :bye}.
      capture_log(fn ->
        for code <- ~w(q Q q Q) do
          Surface.send_event(surface, key(code))
          assert_receive {:mounted, _opts}, 1_000
        end
      end)

      assert Process.alive?(surface)
    end

    test "invalid max_restarts and max_seconds are rejected" do
      Process.flag(:trap_exit, true)

      for {key, value} <- [max_restarts: -1, max_seconds: 0] do
        capture_log(fn ->
          assert {:error, {%ArgumentError{message: message}, _}} =
                   TestSurface.start_link([{key, value}, test_pid: self()])

          assert message =~ inspect(key)
        end)
      end
    end

    test "a restarted app that fails to mount stops the surface" do
      Process.flag(:trap_exit, true)
      counter = start_supervised!({Agent, fn -> 0 end})
      surface = start_surface(on_app_exit: :restart, app_opts: [mount_counter: counter])

      capture_log(fn ->
        Surface.send_event(surface, key("q"))
        assert_receive {:EXIT, ^surface, :no_remount}
      end)

      assert_receive {:terminated, :no_remount}
    end

    test "an app server that does not stop in time is killed" do
      surface = start_surface(shutdown_timeout: 50, app_opts: [hang_terminate: true])
      server = Surface.server(surface)
      ref = Process.monitor(server)

      # The killed server's task supervisor logs its own exit.
      capture_log(fn -> GenServer.stop(surface) end)
      assert_receive {:DOWN, ^ref, :process, ^server, :killed}
      assert_receive {:terminated, :normal}
    end

    test "stopping the surface stops the app server" do
      surface = start_surface()
      server = Surface.server(surface)
      ref = Process.monitor(server)

      GenServer.stop(surface)
      assert_receive {:DOWN, ^ref, :process, ^server, _reason}
      assert_receive {:terminated, :normal}
    end
  end

  describe "telemetry" do
    setup do
      attach([
        [:raster_ex_ratatui, :surface, :start],
        [:raster_ex_ratatui, :surface, :stop],
        [:raster_ex_ratatui, :frame, :raster, :stop],
        [:raster_ex_ratatui, :frame, :push, :stop],
        [:raster_ex_ratatui, :input, :forward]
      ])

      :ok
    end

    test "covers the surface lifecycle, rasterisation, pushes, and input" do
      # Other async tests run surfaces too; every assertion pins this surface's pid.
      {:ok, surface} = TestSurface.start_link(test_pid: self())
      meta = %{surface: TestSurface, mod: RasterExRatatui.Test.App, pid: surface}

      assert_receive {:telemetry, [_, :surface, :start],
                      %{pid: ^surface, size: {240, 160}, grid_size: {40, 20}} = start}

      assert Map.take(start, [:surface, :mod, :pid]) == meta

      assert_receive {:telemetry, [_, :frame, :raster, :stop],
                      %{pid: ^surface, diffs: 1, cells: 800, regions: 0, patches: 20}}

      assert_receive {:telemetry, [_, :frame, :push, :stop],
                      %{pid: ^surface, push_mode: :patches}}

      Surface.send_event(surface, key("a"))

      assert_receive {:telemetry, [_, :input, :forward], %{pid: ^surface, event: %Key{code: "a"}}}

      GenServer.stop(surface)
      assert_receive {:telemetry, [_, :surface, :stop], %{pid: ^surface, reason: :normal}}
    end
  end

  def forward_event(event, _measurements, meta, test_pid),
    do: send(test_pid, {:telemetry, event, meta})

  # Forwards `events` to the test process for the rest of the test.
  defp attach(events) do
    id = "surface-test-#{System.unique_integer([:positive])}"
    :telemetry.attach_many(id, events, &__MODULE__.forward_event/4, self())
    on_exit(fn -> :telemetry.detach(id) end)
  end

  defp flush_mailbox do
    receive do
      message -> [message | flush_mailbox()]
    after
      0 -> []
    end
  end
end
