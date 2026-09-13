defmodule RasterExRatatui.FontTest do
  use ExUnit.Case, async: true

  alias RasterExRatatui.Font
  alias RasterExRatatui.Font.{Art, Default6x8, Generated}

  doctest Font
  doctest Art
  doctest Generated
  doctest Default6x8

  # The badge font's tests described glyphs as 8 bytes whose top six bits
  # are the cell columns; keep those literals and pack them into the
  # 48-bit layout here.
  defp bytes(list), do: for(byte <- list, into: <<>>, do: <<Bitwise.bsr(byte, 2)::6>>)
  defp bytes(byte, count), do: bytes(List.duplicate(byte, count))
  defp dup(byte, count), do: List.duplicate(byte, count)

  describe "Default6x8.glyph/1" do
    test "every glyph, and the placeholder, is exactly 48 bits" do
      for codepoint <- [0x2764 | Default6x8.codepoints()] do
        assert bit_size(Default6x8.glyph(codepoint)) == 48
      end
    end

    test "?A renders the canonical capital-A bitmap" do
      assert Default6x8.glyph(?A) ==
               bytes([
                 0b01110000,
                 0b10001000,
                 0b10001000,
                 0b11111000,
                 0b10001000,
                 0b10001000,
                 0b10001000,
                 0
               ])
    end

    test "5×7 text glyphs keep the spacing column and row blank" do
      for codepoint <- Enum.concat([?0..?9, ?A..?Z, ?a..?z]) do
        rows = Default6x8.glyph(codepoint) |> Art.render({6, 8}) |> String.split("\n", trim: true)
        assert Enum.all?(rows, &String.ends_with?(&1, ".")), "#{[codepoint]} inks column 5"
        assert List.last(rows) == "......", "#{[codepoint]} inks row 7"
      end
    end

    test "space is blank and 0 is not" do
      assert Default6x8.glyph(?\s) == <<0::48>>
      assert Default6x8.has_glyph?(?0)
      refute Default6x8.glyph(?0) == <<0::48>>
    end

    test "─ fills row 3, │ fills column 2, █ fills the cell" do
      assert Default6x8.glyph(0x2500) == bytes([0, 0, 0, 0b11111100, 0, 0, 0, 0])
      assert Default6x8.glyph(0x2502) == bytes(0b00100000, 8)
      assert Default6x8.glyph(0x2588) == bytes(0b11111100, 8)
    end

    test "unknown codepoints return the hatched placeholder" do
      assert Default6x8.glyph(0x2764) ==
               bytes([
                 0b10101010,
                 0b01010100,
                 0b10101010,
                 0b01010100,
                 0b10101010,
                 0b01010100,
                 0b10101010,
                 0
               ])
    end
  end

  describe "Default6x8 generated braille (U+2800..U+28FF)" do
    test "every pattern is encoded" do
      assert Enum.all?(0x2800..0x28FF, &Default6x8.has_glyph?/1)
    end

    test "dots are solid 3×2 blocks" do
      assert Default6x8.glyph(0x2800) == <<0::48>>
      assert Default6x8.glyph(0x2801) == bytes([0b11100000, 0b11100000, 0, 0, 0, 0, 0, 0])
      assert Default6x8.glyph(0x2880) == bytes([0, 0, 0, 0, 0, 0, 0b00011100, 0b00011100])

      assert Default6x8.glyph(0x2848) ==
               bytes([0b00011100, 0b00011100, 0, 0, 0, 0, 0b11100000, 0b11100000])

      assert Default6x8.glyph(0x28FF) == bytes(0b11111100, 8)
    end
  end

  describe "Default6x8 generated block elements" do
    test "lower eighth blocks ▁..▇ fill that many rows from the bottom" do
      for {cp, rows} <- Enum.zip(0x2581..0x2587, 1..7) do
        assert Default6x8.glyph(cp) ==
                 bytes(dup(0, 8 - rows) ++ dup(0b11111100, rows))
      end
    end

    test "▌ is the left half and ▐ the right half" do
      assert Default6x8.glyph(0x258C) == bytes(0b11100000, 8)
      assert Default6x8.glyph(0x2590) == bytes(0b00011100, 8)
    end

    test "left eighth blocks ▏..▉ round to whole columns" do
      assert Default6x8.glyph(0x258F) == bytes(0b10000000, 8)
      assert Default6x8.glyph(0x258E) == bytes(0b11000000, 8)
      assert Default6x8.glyph(0x258B) == bytes(0b11110000, 8)
      assert Default6x8.glyph(0x2589) == bytes(0b11111000, 8)
    end

    test "▔ is the top row and ▕ the right column" do
      assert Default6x8.glyph(0x2594) == bytes([0b11111100, 0, 0, 0, 0, 0, 0, 0])
      assert Default6x8.glyph(0x2595) == bytes(0b00000100, 8)
    end

    test "quadrants split the cell 3×4" do
      assert Default6x8.glyph(0x2598) == bytes(dup(0b11100000, 4) ++ dup(0, 4))
      assert Default6x8.glyph(0x259D) == bytes(dup(0b00011100, 4) ++ dup(0, 4))
      assert Default6x8.glyph(0x2596) == bytes(dup(0, 4) ++ dup(0b11100000, 4))
      assert Default6x8.glyph(0x2597) == bytes(dup(0, 4) ++ dup(0b00011100, 4))
      assert Default6x8.glyph(0x259A) == bytes(dup(0b11100000, 4) ++ dup(0b00011100, 4))
      assert Default6x8.glyph(0x259E) == bytes(dup(0b00011100, 4) ++ dup(0b11100000, 4))
    end

    test "three-quadrant blocks leave exactly one corner blank" do
      full = dup(0b11111100, 4)
      assert Default6x8.glyph(0x2599) == bytes(dup(0b11100000, 4) ++ full)
      assert Default6x8.glyph(0x259B) == bytes(full ++ dup(0b11100000, 4))
      assert Default6x8.glyph(0x259C) == bytes(full ++ dup(0b00011100, 4))
      assert Default6x8.glyph(0x259F) == bytes(dup(0b00011100, 4) ++ full)
    end
  end

  describe "Default6x8.has_glyph?/1 and codepoints/0" do
    test "covers text, box drawing, and block elements" do
      box = [
        0x2500,
        0x2502,
        0x250C,
        0x2510,
        0x2514,
        0x2518,
        0x251C,
        0x2524,
        0x252C,
        0x2534,
        0x253C
      ]

      blocks = [0x2580, 0x2584, 0x2588, 0x2591, 0x2592, 0x2593]
      text = Enum.concat([?0..?9, ?A..?Z, ?a..?z, [?\s, ?., ?,, ?:, ?+, ?-, ??, ?!]])

      for cp <- Enum.concat([text, box, blocks]) do
        assert Default6x8.has_glyph?(cp), "expected glyph for U+#{Integer.to_string(cp, 16)}"
      end

      refute Default6x8.has_glyph?(0x2764)
    end

    test "covers all of printable ASCII, keeping the spacing column and row blank" do
      for codepoint <- 0x20..0x7E do
        assert Default6x8.has_glyph?(codepoint), "expected glyph for #{[codepoint]}"
        rows = Default6x8.glyph(codepoint) |> Art.render({6, 8}) |> String.split("\n", trim: true)
        assert Enum.all?(rows, &String.ends_with?(&1, ".")), "#{[codepoint]} inks column 5"
        assert List.last(rows) == "......", "#{[codepoint]} inks row 7"
      end
    end

    test "every Block border type draws without placeholders" do
      alias ExRatatui.CellSession
      alias ExRatatui.Layout.Rect
      alias ExRatatui.Widgets.Block

      session = CellSession.new(12, 4)

      for border_type <- [:plain, :rounded, :double, :thick] do
        block = %Block{borders: [:all], border_type: border_type}
        :ok = CellSession.draw(session, [{block, %Rect{x: 0, y: 0, width: 12, height: 4}}])
        %{cells: cells} = CellSession.take_cells(session)

        for %{symbol: symbol} <- cells, symbol != "" do
          assert Default6x8.has_glyph?(Font.codepoint(symbol)),
                 "#{border_type} border uses #{symbol}, which has no glyph"
        end
      end

      CellSession.close(session)
    end

    test "rounded corners meet the light lines at column 2 and row 3" do
      corner = fn codepoint ->
        Default6x8.glyph(codepoint) |> Art.render({6, 8}) |> String.split("\n", trim: true)
      end

      assert corner.(0x256D) |> Enum.at(3) |> String.ends_with?("#")
      assert corner.(0x256D) |> List.last() |> String.at(2) == "#"
      assert corner.(0x256E) |> Enum.at(3) |> String.starts_with?("#")
      assert corner.(0x256F) |> hd() |> String.at(2) == "#"
      assert corner.(0x2570) |> Enum.at(3) |> String.ends_with?("#")
    end

    test "heavy and double lines tile across cells" do
      assert Default6x8.glyph(0x2501) == bytes([0, 0, 0, 0b11111100, 0b11111100, 0, 0, 0])
      assert Default6x8.glyph(0x2503) == bytes(0b00110000, 8)
      assert Default6x8.glyph(0x2550) == bytes([0, 0, 0b11111100, 0, 0b11111100, 0, 0, 0])
      assert Default6x8.glyph(0x2551) == bytes(0b01010000, 8)
    end

    test "covers the common symbols" do
      for codepoint <- ~c"°·•…←↑→↓✓✗▲▶▼◀○●" do
        assert Default6x8.has_glyph?(codepoint), "expected glyph for #{[codepoint]}"
      end
    end

    test "codepoints/0 is sorted and matches has_glyph?/1" do
      codepoints = Default6x8.codepoints()
      assert codepoints == Enum.sort(codepoints)
      assert Enum.all?(codepoints, &Default6x8.has_glyph?/1)
    end
  end

  describe "Generated at other cell sizes" do
    test "glyphs always have width × height bits" do
      for size <- [{1, 1}, {5, 9}, {8, 16}, {12, 24}],
          glyphs <- [Generated.braille(size), Generated.eighths(size), Generated.quadrants(size)],
          {_cp, bits} <- glyphs do
        {w, h} = size
        assert bit_size(bits) == w * h
      end
    end

    test "braille dots tile the cell without gaps or overlaps at 8×16" do
      single_dots = for bit <- 0..7, do: Generated.braille({8, 16})[0x2800 + Bitwise.bsl(1, bit)]

      counts =
        Enum.map(single_dots, fn bits -> for(<<b::1 <- bits>>, reduce: 0, do: (n -> n + b)) end)

      assert counts == List.duplicate(16, 8)
      assert Generated.braille({8, 16})[0x28FF] == <<-1::128>>
    end
  end

  describe "Art.parse/3" do
    test "rejects art of the wrong shape or with unknown characters" do
      assert_raise ArgumentError, ~r/expected 2 rows/, fn -> Art.parse("##\n", {2, 2}) end
      assert_raise ArgumentError, ~r/expected 2 columns/, fn -> Art.parse("#\n#\n", {2, 2}) end
      assert_raise ArgumentError, ~r/expected # or \./, fn -> Art.parse("#x\n..\n", {2, 2}) end
    end

    test "round-trips through render/2" do
      art = "#..#\n.##.\n#..#\n"
      assert art |> Art.parse({4, 3}) |> Art.render({4, 3}) == art
    end
  end
end
