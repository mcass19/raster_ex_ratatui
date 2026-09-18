defmodule RasterExRatatui.SessionTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ExRatatui.CellSession.{Cell, Diff}
  alias ExRatatui.Event.Key
  alias RasterExRatatui.{Patch, Raster, Session}
  alias RasterExRatatui.PixelFormat.Mono
  alias RasterExRatatui.Test.{App, FailingApp}

  setup do
    Process.flag(:trap_exit, true)
    %{raster: Raster.new(size: {240, 160}, format: Mono)}
  end

  defp start(raster, opts \\ []), do: Session.start(raster, Keyword.put_new(opts, :app, App))

  # A session whose first render has been folded in.
  defp start_rendered(raster, opts \\ []) do
    {:ok, session} = start(raster, opts)
    {:render, _patches, session} = Session.await(session)
    session
  end

  defp key(code), do: %Key{code: code, kind: "press"}

  defp area(patches), do: Enum.sum(Enum.map(patches, &(&1.width * &1.height)))

  defp blit_all(frame, patches, width, bpp),
    do: Enum.reduce(patches, frame, &Patch.blit(&2, width, bpp, &1))

  describe "start/2" do
    test "starts the app linked, with the panel in its options, and the first render is the whole panel",
         %{raster: raster} do
      {:ok, session} = start(raster, app_opts: [notify: self()])

      assert_receive {:mounted, opts}

      assert opts[:surface] == %{
               size: {240, 160},
               cell_size: {6, 8},
               grid_size: {40, 20},
               format: Mono,
               scale: 1,
               rotate: 0
             }

      server = Session.server(session)
      assert is_pid(server)
      assert {:links, links} = Process.info(self(), :links)
      assert server in links
      assert Session.grid_size(session) == {40, 20}

      assert {:render, patches, session} = Session.await(session)
      assert area(patches) == 240 * 160
      assert Session.raster(session).grid.width == 40

      assert :ok = Session.stop(session)
      refute Process.alive?(server)
      refute_received {:EXIT, ^server, _reason}
    end

    test "requires :app", %{raster: raster} do
      assert_raise ArgumentError, ~r/:app/, fn -> Session.start(raster, []) end
    end

    test "an app that fails to mount leaves nothing running", %{raster: raster} do
      assert {:error, :no_mount} = start(raster, app: FailingApp)
    end
  end

  describe "handle/2" do
    test "folds every render waiting in the mailbox into one and returns the patches",
         %{raster: raster} do
      session = start_rendered(raster)
      before = Raster.frame(Session.raster(session))

      for code <- ~w(a b c), do: Session.send_event(session, key(code))

      messages =
        for _ <- 1..3 do
          assert_receive {Session, _ref, %Diff{}} = message
          message
        end

      Enum.each(messages, &send(self(), &1))

      assert {:render, patches, session} = Session.handle(session, hd(messages))
      refute_received {Session, _ref, _diff}
      # "hi" plus the three typed letters: five cells, drawn in one render.
      assert patches |> Enum.map(&(&1.x + &1.width)) |> Enum.max() == 30
      assert blit_all(before, patches, 240, 1) == Raster.frame(Session.raster(session))
    end

    test "a render that changes nothing gives no patches", %{raster: raster} do
      session = start_rendered(raster)
      send(Session.server(session), :unrelated)

      assert_receive {Session, _ref, %Diff{ops: []}} = message
      assert {:render, [], _session} = Session.handle(session, message)
    end

    test "a render from before a resize is dropped", %{raster: raster} do
      session = start_rendered(raster)
      stale = %Diff{width: 3, height: 3, ops: [%Cell{symbol: "x"}]}

      assert {:render, [], ^session} = Session.handle(session, {Session, session.ref, stale})
    end

    test "the app's exit ends the session, and a new one on the same raster repaints",
         %{raster: raster} do
      session = start_rendered(raster)
      server = Session.server(session)

      log =
        capture_log(fn ->
          Session.send_event(session, key("!"))
          assert_receive {:EXIT, ^server, _reason} = message

          assert {:exit, {%RuntimeError{message: "boom"}, _stack}, session} =
                   Session.handle(session, message)

          assert Session.server(session) == nil
          assert :ok = Session.send_event(session, key("a"))
          assert :ok = Session.stop(session)

          {:ok, again} = start(Session.raster(session))
          assert {:render, patches, again} = Session.await(again)
          assert area(patches) == 240 * 160
          assert :ok = Session.stop(again)
        end)

      assert log =~ "boom"
    end

    test "anything else is :unknown", %{raster: raster} do
      session = start_rendered(raster)

      for message <- [:hello, {:EXIT, self(), :normal}, {Session, make_ref(), %Diff{}}] do
        assert Session.handle(session, message) == :unknown
      end
    end

    test "drain/2 and render/2 are its two halves", %{raster: raster} do
      session = start_rendered(raster)
      Session.send_event(session, key("a"))

      assert_receive {Session, _ref, %Diff{}} = message
      assert {:diffs, [%Diff{} = diff], session} = Session.drain(session, message)
      assert {[], ^session} = Session.render(session, [])

      assert {[%Patch{x: 12, y: 0, width: 6, height: 8}], _session} =
               Session.render(session, [diff])
    end
  end

  describe "await/2" do
    test "times out when the app has nothing to say", %{raster: raster} do
      session = start_rendered(raster)
      assert {:timeout, ^session} = Session.await(session, 50)
    end

    test "reports the app's exit", %{raster: raster} do
      session = start_rendered(raster)
      Session.send_event(session, key("q"))

      assert {:exit, :normal, session} = Session.await(session)
      assert :ok = Session.stop(session)
    end
  end

  describe "keep_frame: true" do
    test "keeps frame/1 equal to the raster's frame across renders", %{raster: raster} do
      session = start_rendered(raster, keep_frame: true)
      assert Session.frame(session) == Raster.frame(Session.raster(session))

      Session.send_event(session, key("a"))
      assert {:render, [_patch], session} = Session.await(session)
      assert Session.frame(session) == Raster.frame(Session.raster(session))
    end

    test "is rebuilt by a resize", %{raster: raster} do
      session = start_rendered(raster, keep_frame: true)
      session = Session.resize(session, {120, 80})

      assert Session.grid_size(session) == {20, 10}
      assert byte_size(Session.frame(session)) == 120 * 80

      assert {:render, patches, session} = Session.await(session)
      assert area(patches) == 120 * 80
      assert Session.frame(session) == Raster.frame(Session.raster(session))
    end
  end

  test "frame/1 renders the raster without keep_frame", %{raster: raster} do
    session = start_rendered(raster)
    assert Session.frame(session) == Raster.frame(Session.raster(session))
  end

  describe "resize/2" do
    test "rebuilds the grid and the app's next render repaints it", %{raster: raster} do
      session = start_rendered(raster)
      session = Session.resize(session, {120, 80})

      assert Session.grid_size(session) == {20, 10}
      assert {:render, patches, _session} = Session.await(session)
      assert area(patches) == 120 * 80
    end

    test "after the app's exit only the raster changes", %{raster: raster} do
      session = start_rendered(raster)
      Session.send_event(session, key("q"))
      assert {:exit, :normal, session} = Session.await(session)

      session = Session.resize(session, {120, 80})
      assert Session.grid_size(session) == {20, 10}

      {:ok, again} = start(Session.raster(session))
      assert {:render, patches, again} = Session.await(again)
      assert area(patches) == 120 * 80
      assert :ok = Session.stop(again)
    end
  end

  describe "stop/1" do
    test "kills an app that does not stop in time", %{raster: raster} do
      session = start_rendered(raster, shutdown_timeout: 50, app_opts: [hang_terminate: true])
      server = Session.server(session)
      ref = Process.monitor(server)

      # The killed server's task supervisor logs its own exit.
      capture_log(fn -> assert :ok = Session.stop(session) end)
      assert_receive {:DOWN, ^ref, :process, ^server, :killed}
      refute_received {:EXIT, ^server, _reason}
    end
  end
end
