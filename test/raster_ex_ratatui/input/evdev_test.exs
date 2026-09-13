defmodule RasterExRatatui.Input.EvdevTest do
  use ExUnit.Case, async: true

  alias ExRatatui.Event.Key
  alias RasterExRatatui.Input.Evdev

  doctest Evdev

  defp press(code), do: {:ev_key, code, 1}
  defp release(code), do: {:ev_key, code, 0}

  defp keys(events, opts \\ []) do
    {_keyboard, keys} = Evdev.translate_all(Evdev.new(opts), events)
    keys
  end

  defp codes(events, opts \\ []), do: Enum.map(keys(events, opts), &{&1.code, &1.modifiers})

  test "letters, digits, and punctuation type their unshifted characters" do
    events = Enum.map(~w(key_h key_i key_space key_1 key_minus key_slash key_grave)a, &press/1)
    assert Enum.map(keys(events), & &1.code) == ["h", "i", " ", "1", "-", "/", "`"]
  end

  test "shift types the shifted character and is reported as a modifier" do
    events = [press(:key_rightshift), press(:key_a), press(:key_2), press(:key_apostrophe)]
    assert codes(events) == [{"A", ["shift"]}, {"@", ["shift"]}, {"\"", ["shift"]}]
  end

  test "releasing a modifier clears it, and either side counts" do
    events = [
      press(:key_leftshift),
      press(:key_rightshift),
      release(:key_leftshift),
      press(:key_a),
      release(:key_rightshift),
      press(:key_a)
    ]

    assert codes(events) == [{"A", ["shift"]}, {"a", []}]
  end

  test "modifiers are reported in shift, ctrl, alt, super order" do
    events = [
      press(:key_leftmeta),
      press(:key_rightalt),
      press(:key_leftctrl),
      press(:key_leftshift),
      press(:key_x)
    ]

    assert codes(events) == [{"X", ["shift", "ctrl", "alt", "super"]}]
  end

  test "caps lock uppercases letters only, and shift undoes it" do
    events = [
      press(:key_capslock),
      release(:key_capslock),
      press(:key_a),
      press(:key_1),
      press(:key_leftshift),
      press(:key_a),
      press(:key_1),
      release(:key_leftshift),
      press(:key_capslock),
      press(:key_a)
    ]

    assert codes(events) == [
             {"caps_lock", []},
             {"A", []},
             {"1", []},
             {"a", ["shift"]},
             {"!", ["shift"]},
             {"caps_lock", []},
             {"a", []}
           ]
  end

  test "special keys use ExRatatui's codes, shift+tab is back_tab" do
    specials =
      ~w(key_enter key_kpenter key_esc key_backspace key_delete key_pageup key_up key_f12 key_sysrq)a

    assert Enum.map(keys(Enum.map(specials, &press/1)), & &1.code) ==
             ~w(enter enter esc backspace delete page_up up f12 print_screen)

    assert codes([press(:key_tab), press(:key_leftshift), press(:key_tab)]) ==
             [{"tab", []}, {"back_tab", ["shift"]}]
  end

  test "keypad keys type characters regardless of shift" do
    events = [press(:key_leftshift), press(:key_kp7), press(:key_kpasterisk)]
    assert codes(events) == [{"7", ["shift"]}, {"*", ["shift"]}]
  end

  test "repeats are emitted, releases only when asked" do
    events = [press(:key_j), {:ev_key, :key_j, 2}, release(:key_j)]

    assert Enum.map(keys(events), & &1.kind) == ["press", "repeat"]
    assert Enum.map(keys(events, emit_release: true), & &1.kind) == ["press", "repeat", "release"]
  end

  test "unmapped keys and non-key events produce nothing" do
    events = [
      press(:key_volumeup),
      {:ev_key, :key_a, 7},
      {:ev_rel, :rel_x, 3},
      {:ev_syn, :syn_report, 0}
    ]

    assert keys(events) == []
  end

  test "a layout map overrides the US table" do
    layout = %{key_z: {"y", "Y"}, key_y: {"z", "Z"}}

    assert codes([press(:key_z), press(:key_leftshift), press(:key_y)], layout: layout) == [
             {"y", []},
             {"Z", ["shift"]}
           ]
  end

  test "keys are ExRatatui.Event.Key structs" do
    assert [%Key{code: "q", kind: "press", modifiers: []}] = keys([press(:key_q)])
  end
end
