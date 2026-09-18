defmodule RasterExRatatui.Input.DevicesTest do
  use ExUnit.Case, async: true

  alias ExRatatui.Event.Key
  alias RasterExRatatui.Input.Devices
  alias RasterExRatatui.Test.Input

  doctest Devices

  @moduletag :capture_log

  @keyboard {"/dev/input/event1", %{report_info: [ev_key: [:key_esc, :key_a, :key_tab]]}}
  @touch {"/dev/input/event0", %{report_info: [ev_key: [:btn_touch], ev_abs: [abs_x: %{}]]}}

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  defp new(opts \\ []), do: Devices.new(Keyword.merge([input: Input, retry_ms: 20], opts))

  # Starts and runs the first scan.
  defp scanned(opts \\ []) do
    {:ok, devices} = Devices.start(new(opts))
    assert_receive {Devices, :scan} = scan
    {:noreply, devices} = Devices.handle_info(scan, devices)
    devices
  end

  defp press(code), do: [{:ev_key, code, 1}, {:ev_syn, :syn_report, 0}]

  describe "new/1" do
    test "rejects bad options" do
      for {key, value} <- [keyboard: :maybe, touch: 1, retry_ms: -1, input: nil] do
        assert_raise ArgumentError, ~r/#{inspect(key)}/, fn -> new([{key, value}]) end
      end
    end

    test "defaults to the keyboard through InputEvent" do
      assert %Devices{input: InputEvent, keyboard: true, touch: false, retry_ms: 2_000} =
               Devices.new()
    end

    test "passes the layout on to Evdev" do
      devices = new(layout: %{key_a: {"q", "Q"}})
      assert devices.evdev.chars.key_a == {"q", "Q"}
    end
  end

  describe "start/1" do
    test "does nothing when no device is wanted" do
      assert {:ok, _devices} = Devices.start(new(keyboard: false, touch: false))
      refute_received {Devices, :scan}
    end

    test "reports a missing input_event" do
      assert {:error, :input_event_missing} = Devices.start(new(input: No.Such.Module))
    end

    test "with only a touch panel wanted scans and reads nothing yet" do
      Input.devices([@touch, @keyboard])
      devices = scanned(keyboard: false, touch: true)

      refute_received :enumerated
      refute_received {:reader, _reader, _opts}
      assert devices.timer == nil
    end

    test "started again while a scan is pending does not queue a second one" do
      Input.devices([])
      devices = scanned()
      assert devices.timer != nil

      assert {:ok, ^devices} = Devices.start(devices)
      assert_receive {Devices, :scan}, 200
      refute_receive {Devices, :scan}, 100
    end
  end

  describe "the keyboard" do
    test "is the first device with letter keys, grabbed, and its keys come back as events" do
      Input.devices([@touch, @keyboard])
      devices = scanned()

      assert_received :enumerated
      assert_received {:reader, reader, path: "/dev/input/event1", grab: true}
      assert Devices.keyboard(devices) == "/dev/input/event1"
      assert Process.alive?(reader)

      events = press(:key_leftshift) ++ press(:key_a)

      assert {:events, [%Key{code: "A", modifiers: ["shift"]}], devices} =
               Devices.handle_info({:input_event, "/dev/input/event1", events}, devices)

      assert {:events, [], _devices} =
               Devices.handle_info({:input_event, "/dev/input/event1", []}, devices)
    end

    test "is read at a fixed path without enumerating" do
      devices = scanned(keyboard: "/dev/input/event7")

      refute_received :enumerated
      assert_received {:reader, _reader, path: "/dev/input/event7", grab: true}
      assert Devices.keyboard(devices) == "/dev/input/event7"
    end

    test "is looked for again until it shows up" do
      Input.devices([@touch])
      devices = scanned()
      assert Devices.keyboard(devices) == nil
      refute_received {:reader, _, _}

      Input.devices([@touch, @keyboard])
      assert_receive {Devices, :scan} = scan, 200
      {:noreply, devices} = Devices.handle_info(scan, devices)
      assert Devices.keyboard(devices) == "/dev/input/event1"
    end

    test "is retried when it cannot be opened" do
      Input.devices([@keyboard])
      Input.fail_next(:eacces)
      devices = scanned()
      assert Devices.keyboard(devices) == nil

      assert_receive {Devices, :scan} = scan, 200
      {:noreply, devices} = Devices.handle_info(scan, devices)
      assert Devices.keyboard(devices) == "/dev/input/event1"
    end

    test "is found again after it goes away, with the modifiers released" do
      Input.devices([@keyboard])
      devices = scanned()
      assert_received {:reader, reader, _opts}

      # Shift held, then the keyboard is unplugged: the reader reports the
      # disconnect and exits, the next keyboard starts clean.
      {:events, [], devices} =
        Devices.handle_info({:input_event, "/dev/input/event1", press(:key_leftshift)}, devices)

      assert {:noreply, devices} =
               Devices.handle_info({:input_event, "/dev/input/event1", :disconnect}, devices)

      assert {:events, [%Key{code: "a", modifiers: []}], devices} =
               Devices.handle_info({:input_event, "/dev/input/event1", press(:key_a)}, devices)

      Process.exit(reader, :kill)
      assert_receive {:EXIT, ^reader, :killed} = exit
      assert {:noreply, devices} = Devices.handle_info(exit, devices)

      assert_received {:reader, again, _opts}
      assert again != reader
      assert Devices.keyboard(devices) == "/dev/input/event1"
    end

    test "is not looked for while one is being read" do
      Input.devices([@keyboard])
      devices = scanned()
      assert_received :enumerated

      assert {:noreply, ^devices} = Devices.handle_info({Devices, :scan}, devices)
      refute_received :enumerated
    end
  end

  describe "handle_info/2" do
    test "says :unknown to everything else" do
      Input.devices([@keyboard])
      devices = scanned()

      for msg <- [
            :hello,
            {:input_event, "/dev/input/event9", press(:key_a)},
            {:input_event, "/dev/input/event9", :disconnect},
            {:EXIT, self(), :normal}
          ] do
        assert Devices.handle_info(msg, devices) == :unknown
      end
    end
  end

  describe "stop/1" do
    test "stops the reader, and its exit is then nobody's business" do
      Input.devices([@keyboard])
      devices = scanned()
      assert_received {:reader, reader, _opts}

      devices = Devices.stop(devices)
      assert_received {:stopped, ^reader}
      assert_receive {:EXIT, ^reader, :normal} = exit
      assert Devices.keyboard(devices) == nil
      assert Devices.handle_info(exit, devices) == :unknown

      # Idempotent, and cancels a pending scan.
      Input.devices([])
      {:ok, waiting} = Devices.start(devices)
      assert_receive {Devices, :scan} = scan
      {:noreply, waiting} = Devices.handle_info(scan, waiting)
      assert waiting.timer != nil
      assert Devices.stop(waiting).timer == nil
      refute_receive {Devices, :scan}, 100
    end
  end
end
