defmodule RasterExRatatui.RasterTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import RasterExRatatui.Test.Frames

  alias ExRatatui.CellSession
  alias ExRatatui.CellSession.{Cell, Diff, Region, Snapshot}
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Widgets.Paragraph
  alias RasterExRatatui.Font.{Art, Default6x8}
  alias RasterExRatatui.{Grid, Patch, Raster}
  alias RasterExRatatui.PixelFormat.{Mono, RGB565, XRGB8888}
  alias RasterExRatatui.Test.Rotation

  doctest Grid
  doctest Patch
  doctest Raster

  @ink <<0>>
  @paper <<255>>

  defp mono(size \\ {24, 16}, opts \\ []) do
    Raster.new([size: size, font: Default6x8, format: Mono] ++ opts)
  end

  defp render(raster, cells, regions \\ []) do
    {raster, _patches} = Raster.apply(raster, full_diff(Raster.grid_size(raster), cells, regions))
    {raster, Raster.frame(raster)}
  end

  defp pixels(frame, raster, xs, ys), do: for(y <- ys, x <- xs, do: pixel(frame, raster, x, y))

  describe "new/1" do
    test "requires :size and :format, as ArgumentError" do
      assert_raise ArgumentError, "missing required option :size", fn ->
        Raster.new(format: Mono)
      end

      assert_raise ArgumentError, "missing required option :format", fn ->
        Raster.new(size: {24, 16})
      end
    end

    test "rejects a size that is not a pair of positive integers" do
      for size <- [{0, 16}, {24, -1}, {24.0, 16}, [24, 16], nil] do
        assert_raise ArgumentError, ~r/expected :size to be \{width, height\}/, fn ->
          mono(size)
        end
      end
    end

    test "rejects a non-positive or non-integer scale" do
      for scale <- [0, -1, 1.5, nil] do
        assert_raise ArgumentError, ~r/:scale/, fn -> mono({24, 16}, scale: scale) end
      end
    end

    test "rejects a panel smaller than one cell" do
      assert_raise ArgumentError, ~r/fits no 12x16 cell/, fn -> mono({11, 100}, scale: 2) end
      assert_raise ArgumentError, ~r/fits no 6x8 cell/, fn -> mono({100, 7}) end
    end

    test "passes format_opts to the format and keeps them across resize" do
      raster = mono({24, 16}, format_opts: [ink_max: 200])
      assert raster.config.ink_max == 200
      assert Raster.resize(raster, {48, 32}).config.ink_max == 200
    end
  end

  describe "frame/1 with Mono (the badge tone rules, pixel by pixel)" do
    test "an empty raster is uniform paper, margins included" do
      raster = mono({400, 300})
      assert Raster.frame(raster) == :binary.copy(@paper, 400 * 300)
    end

    test "a cell paints exactly its glyph at its origin" do
      {raster, frame} = render(mono(), [%Cell{col: 1, row: 1, symbol: "A"}])

      art =
        for y <- 8..15, into: "" do
          row =
            for x <- 6..11,
                into: "",
                do: if(pixel(frame, raster, x, y) == @ink, do: "#", else: ".")

          row <> "\n"
        end

      assert art == Art.render(Default6x8.glyph(?A), {6, 8})
      assert Enum.all?(pixels(frame, raster, 0..23, 0..7), &(&1 == @paper))
    end

    test "skip cells render as a blank cell whatever they hold" do
      cell = %Cell{symbol: "█", fg: :black, bg: :black, skip: true}
      {raster, frame} = render(mono(), [cell])
      assert Enum.all?(pixels(frame, raster, 0..5, 0..7), &(&1 == @paper))
    end

    test "margins stay paper under a full ink grid" do
      raster = mono({27, 19})
      cells = for col <- 0..3, row <- 0..1, do: %Cell{col: col, row: row, symbol: "█", fg: :black}
      {raster, frame} = render(raster, cells)

      assert Enum.all?(pixels(frame, raster, 0..23, 0..15), &(&1 == @ink))
      assert Enum.all?(pixels(frame, raster, 24..26, 0..18), &(&1 == @paper))
      assert Enum.all?(pixels(frame, raster, 0..26, 16..18), &(&1 == @paper))
    end

    test "▀ with RGB colours inks each half by luma" do
      cell = %Cell{symbol: "▀", fg: {:rgb, 0, 0, 0}, bg: {:rgb, 255, 255, 255}}
      {raster, frame} = render(mono(), [cell])

      assert Enum.all?(pixels(frame, raster, 0..5, 0..3), &(&1 == @ink))
      assert Enum.all?(pixels(frame, raster, 0..5, 4..7), &(&1 == @paper))
    end

    test "gray is a checkerboard aligned across neighbouring cells" do
      gray = {:rgb, 128, 128, 128}
      cells = for col <- 0..1, do: %Cell{col: col, symbol: "█", fg: gray, bg: gray}
      {raster, frame} = render(mono(), cells)

      assert Enum.count(pixels(frame, raster, 0..5, 0..7), &(&1 == @ink)) == 24

      for x <- 0..10, y <- 0..6 do
        assert pixel(frame, raster, x, y) != pixel(frame, raster, x + 1, y)
        assert pixel(frame, raster, x, y) != pixel(frame, raster, x, y + 1)
      end
    end

    test ":reversed on a black fill punches the glyph out as paper" do
      letter = %Cell{col: 0, symbol: "█", bg: :black, modifiers: [:reversed]}
      gap = %Cell{col: 1, symbol: " ", bg: :black, modifiers: [:reversed]}
      {raster, frame} = render(mono(), [letter, gap])

      assert Enum.all?(pixels(frame, raster, 0..5, 0..7), &(&1 == @paper))
      assert Enum.all?(pixels(frame, raster, 6..11, 0..7), &(&1 == @ink))
    end

    test "scale magnifies every glyph pixel into a square" do
      raster = mono({48, 32}, scale: 2)
      {raster, frame} = render(raster, [%Cell{symbol: "A"}])
      glyph = for <<bit::1 <- Default6x8.glyph(?A)>>, do: bit

      for gy <- 0..7, gx <- 0..5, sy <- 0..1, sx <- 0..1 do
        expected = if Enum.at(glyph, gy * 6 + gx) == 1, do: @ink, else: @paper
        assert pixel(frame, raster, gx * 2 + sx, gy * 2 + sy) == expected
      end
    end
  end

  describe "frame/1 with colour formats" do
    test "XRGB8888 paints the palette's colours and blank margins" do
      raster = Raster.new(size: {7, 8}, format: XRGB8888, format_opts: [reset_bg: {0, 0, 9}])
      {raster, frame} = render(raster, [%Cell{symbol: "█", fg: :red}])

      assert pixel(frame, raster, 0, 0) == <<0, 0, 205, 255>>
      assert pixel(frame, raster, 6, 0) == <<9, 0, 0, 255>>
    end

    test "RGB565 at scale 3 fills the effective cell" do
      raster = Raster.new(size: {18, 24}, format: RGB565, scale: 3)
      {_raster, frame} = render(raster, [%Cell{symbol: "█", fg: {:rgb, 255, 255, 255}}])
      assert frame == :binary.copy(<<255, 255>>, 18 * 24)
    end
  end

  describe "apply/2 patches" do
    test "a full payload repaints every row, then regions, then margins" do
      raster = mono({27, 19})
      region = region(1, 0, 1, 1, {0, 0, 0})
      {_raster, patches} = Raster.apply(raster, full_diff({4, 2}, [], [region]))

      # Row 0 skips the cell under the region.
      assert Enum.map(patches, &{&1.x, &1.y, &1.width, &1.height}) == [
               {0, 0, 6, 8},
               {12, 0, 12, 8},
               {0, 8, 24, 8},
               {6, 0, 6, 8},
               {24, 0, 3, 19},
               {0, 16, 24, 3}
             ]
    end

    test "a snapshot is a full payload too" do
      snapshot = %Snapshot{width: 4, height: 2, cells: []}
      {_raster, patches} = Raster.apply(mono(), snapshot)
      assert length(patches) == 2
    end

    test "changed cells become one patch per contiguous run on a row" do
      {raster, _} = Raster.apply(mono(), full_diff({4, 2}, []))

      ops = [
        %Cell{col: 3, row: 0, symbol: "c"},
        %Cell{col: 0, row: 0, symbol: "a"},
        %Cell{col: 1, row: 0, symbol: "b"},
        %Cell{col: 2, row: 1, symbol: "d"},
        %Cell{col: 1, row: 0, symbol: "b"}
      ]

      {_raster, patches} = Raster.apply(raster, %Diff{width: 4, height: 2, ops: ops})

      assert Enum.map(patches, &{&1.x, &1.y, &1.width, byte_size(&1.data)}) == [
               {0, 0, 12, 96},
               {18, 0, 6, 48},
               {12, 8, 6, 48}
             ]
    end

    test "an empty diff produces no patches" do
      {raster, _} = Raster.apply(mono(), full_diff({4, 2}, []))
      assert {_raster, []} = Raster.apply(raster, %Diff{width: 4, height: 2})
    end

    test "cells outside the raster's grid are ignored" do
      {raster, _} = Raster.apply(mono({24, 8}), full_diff({5, 2}, []))
      diff = %Diff{width: 5, height: 2, ops: [%Cell{col: 4, row: 0}, %Cell{col: 0, row: 1}]}
      assert {_raster, []} = Raster.apply(raster, diff)
    end

    test "cells under a region are skipped while the region stays" do
      region = region(0, 0, 2, 1, {255, 0, 0})
      {raster, _} = Raster.apply(mono(), full_diff({4, 2}, [], [region]))

      diff = %Diff{width: 4, height: 2, ops: [%Cell{col: 1, symbol: "x"}], regions: [region]}
      assert {_raster, []} = Raster.apply(raster, diff)
    end

    test "a region that goes away repaints the cells it covered" do
      region = region(1, 0, 2, 2, {0, 0, 0})
      {raster, _} = Raster.apply(mono(), full_diff({4, 2}, [], [region]))
      {_raster, patches} = Raster.apply(raster, %Diff{width: 4, height: 2})

      assert Enum.map(patches, &{&1.x, &1.y, &1.width}) == [{6, 0, 12}, {6, 8, 12}]
      assert Enum.all?(patches, &(&1.data == :binary.copy(@paper, byte_size(&1.data))))
    end

    test "only the region that changed is repainted" do
      a = region(0, 0, 1, 1, {0, 0, 0})
      b = region(2, 0, 1, 1, {0, 0, 0})
      {raster, _} = Raster.apply(mono(), full_diff({4, 2}, [], [a, b]))

      b2 = region(2, 0, 1, 1, {255, 255, 255})
      {_raster, patches} = Raster.apply(raster, %Diff{width: 4, height: 2, regions: [a, b2]})

      assert Enum.map(patches, &{&1.x, &1.data}) == [{12, :binary.copy(@paper, 48)}]
    end

    test "a region that moves repaints the cells it left and itself, not its neighbour" do
      still = region(0, 0, 1, 1, {0, 0, 0})

      {raster, _} =
        Raster.apply(mono(), full_diff({4, 2}, [], [still, region(2, 0, 1, 1, {0, 0, 0})]))

      moved = region(3, 1, 1, 1, {0, 0, 0})

      {_raster, patches} =
        Raster.apply(raster, %Diff{width: 4, height: 2, regions: [still, moved]})

      assert Enum.map(patches, &{&1.x, &1.y, &1.data}) == [
               {12, 0, :binary.copy(@paper, 48)},
               {18, 8, :binary.copy(@ink, 48)}
             ]
    end

    test "an unchanged region under a changed one is repainted first, so the order holds" do
      below = region(0, 0, 2, 1, {0, 0, 0})
      above = region(1, 0, 2, 1, {0, 0, 0})
      aside = region(3, 1, 1, 1, {0, 0, 0})
      {raster, _} = Raster.apply(mono(), full_diff({4, 2}, [], [below, above, aside]))

      above2 = region(1, 0, 2, 1, {255, 255, 255})
      diff = %Diff{width: 4, height: 2, regions: [below, above2, aside]}
      {raster, patches} = Raster.apply(raster, diff)

      assert Enum.map(patches, &{&1.x, &1.width}) == [{0, 12}, {6, 12}]
      assert pixel(Raster.frame(raster), raster, 3, 0) == @ink
      assert pixel(Raster.frame(raster), raster, 8, 0) == @paper
    end

    test "a region that goes away uncovers the unchanged region it overlapped" do
      below = region(0, 0, 2, 1, {0, 0, 0})
      above = region(1, 0, 2, 1, {255, 255, 255})
      {raster, frame} = render(mono(), [], [below, above])
      assert pixel(frame, raster, 8, 0) == @paper

      {raster, patches} = Raster.apply(raster, %Diff{width: 4, height: 2, regions: [below]})

      assert Enum.map(patches, &{&1.x, &1.width}) == [{12, 6}, {0, 12}]
      assert blit(frame, raster, patches) == Raster.frame(raster)
      assert pixel(Raster.frame(raster), raster, 8, 0) == @ink
    end

    test "unchanged regions that swap places are all repainted" do
      a = region(0, 0, 2, 1, {0, 0, 0})
      b = region(1, 0, 2, 1, {255, 255, 255})
      {raster, frame} = render(mono(), [], [a, b])

      {raster, patches} = Raster.apply(raster, %Diff{width: 4, height: 2, regions: [b, a]})

      assert Enum.map(patches, & &1.x) == [6, 0]
      assert blit(frame, raster, patches) == Raster.frame(raster)
      assert pixel(Raster.frame(raster), raster, 8, 0) == @ink
    end

    test "the same region list again costs nothing" do
      regions = [region(0, 0, 1, 1, {0, 0, 0}), region(2, 0, 1, 1, {9, 9, 9})]
      {raster, _} = Raster.apply(mono(), full_diff({4, 2}, [], regions))

      assert {_raster, []} = Raster.apply(raster, %Diff{width: 4, height: 2, regions: regions})
    end

    test "a list of diffs is rasterised once, in its final state" do
      raster = mono()
      {raster, _} = Raster.apply(raster, full_diff({4, 2}, []))

      diffs =
        for symbol <- ~w(a b c) do
          %Diff{
            width: 4,
            height: 2,
            ops: [%Cell{col: 1, symbol: symbol}, %Cell{col: 2, symbol: symbol}]
          }
        end

      {batched, patches} = Raster.apply(raster, diffs)
      {sequential, _} = Enum.reduce(diffs, {raster, []}, fn d, {r, _} -> Raster.apply(r, d) end)

      assert [%Patch{x: 6, y: 0, width: 12}] = patches
      assert Raster.frame(batched) == Raster.frame(sequential)
    end

    test "a list with a region changing in every diff patches the region once" do
      raster = mono()
      {raster, _} = Raster.apply(raster, full_diff({4, 2}, []))

      diffs =
        for shade <- [0, 128, 255],
            do: %Diff{width: 4, height: 2, regions: [region(0, 0, 2, 1, {shade, shade, shade})]}

      assert {_raster, [%Patch{x: 0, y: 0, width: 12, height: 8, data: data}]} =
               Raster.apply(raster, diffs)

      assert data == :binary.copy(@paper, 96)
    end

    test "a full payload inside a list repaints everything, an empty list nothing" do
      raster = mono()
      {raster, _} = Raster.apply(raster, full_diff({4, 2}, []))

      diffs = [
        %Diff{width: 4, height: 2, ops: [%Cell{symbol: "x"}]},
        full_diff({4, 2}, []),
        %Diff{width: 4, height: 2, ops: [%Cell{col: 3, row: 1, symbol: "y"}]}
      ]

      {_raster, patches} = Raster.apply(raster, diffs)
      assert Enum.map(patches, &{&1.x, &1.y, &1.width}) == [{0, 0, 24}, {0, 8, 24}]

      assert {^raster, []} = Raster.apply(raster, [])
    end

    test "a region bitmap is scaled nearest-neighbour onto its rect" do
      data = <<0, 0, 0, 255, 255, 255, 255, 255, 255, 0, 0, 0>>
      region = %{region(0, 0, 2, 1, {0, 0, 0}) | pixel_width: 2, pixel_height: 2, data: data}
      {raster, frame} = render(mono(), [], [region])

      assert Enum.all?(pixels(frame, raster, 0..5, 0..3), &(&1 == @ink))
      assert Enum.all?(pixels(frame, raster, 6..11, 0..3), &(&1 == @paper))
      assert Enum.all?(pixels(frame, raster, 0..5, 4..7), &(&1 == @paper))
      assert Enum.all?(pixels(frame, raster, 6..11, 4..7), &(&1 == @ink))
    end

    test "a region is rasterised the same through rows and through pixels, scaled or not" do
      raster = Raster.new(size: {24, 16}, format: RasterExRatatui.Test.Gray)
      data = for i <- 1..(6 * 4), into: <<>>, do: <<i, i, i>>
      native = %{region(0, 0, 1, 1, {0, 0, 0}) | pixel_width: 6, pixel_height: 4, data: data}

      scaled = %{
        native
        | x: 1,
          y: 1,
          width: 2,
          pixel_width: 3,
          pixel_height: 2,
          data: binary_part(data, 0, 18)
      }

      {raster, _} = Raster.apply(raster, full_diff({4, 2}, []))

      {_raster, [a, b]} =
        Raster.apply(raster, %Diff{width: 4, height: 2, regions: [native, scaled]})

      assert {a.width, a.height, byte_size(a.data)} == {6, 8, 48}
      assert {b.width, b.height} == {12, 8}
      # Row 0 of the native region is its first six pixels, offset by their column.
      assert binary_part(a.data, 0, 6) == <<1, 3, 5, 7, 9, 11>>
      # The scaled region (3×2 source pixels onto 12×8) repeats every source
      # pixel four times across and every source row four times down; the
      # column offset (from x = 6) still counts per output pixel.
      assert binary_part(b.data, 0, 12) == <<7, 8, 9, 10, 12, 13, 14, 15, 17, 18, 19, 20>>
      assert binary_part(b.data, 12 * 3, 12) == binary_part(b.data, 0, 12)
      assert binary_part(b.data, 12 * 4, 12) == <<10, 11, 12, 13, 15, 16, 17, 18, 20, 21, 22, 23>>
    end

    test "a region hanging past the grid is clipped, and one wholly outside is dropped" do
      hanging = region(3, 1, 4, 4, {0, 0, 0})
      outside = region(4, 0, 1, 1, {0, 0, 0})
      raster = mono({27, 19})
      {_raster, patches} = Raster.apply(raster, full_diff({4, 2}, [], [hanging, outside]))

      assert %Patch{x: 18, y: 8, width: 6, height: 8} = Enum.at(patches, 2)
      assert length(patches) == 5
    end

    test "a region without a bitmap covers nothing" do
      empty = %{region(0, 0, 1, 1, {0, 0, 0}) | pixel_width: 0, data: <<>>}
      {raster, _} = Raster.apply(mono(), full_diff({4, 2}, [], [empty]))

      diff = %Diff{width: 4, height: 2, ops: [%Cell{symbol: "x"}], regions: [empty]}
      assert {_raster, [%Patch{x: 0, y: 0, width: 6}]} = Raster.apply(raster, diff)
    end

    test "the glyph cache is bounded" do
      raster = Raster.new(size: {600, 360}, format: XRGB8888)

      cells =
        for col <- 0..99, row <- 0..44, do: %Cell{col: col, row: row, fg: {:rgb, col, row, 7}}

      {raster, _} = Raster.apply(raster, full_diff({100, 45}, cells))

      assert map_size(raster.cache) < 4096
      assert map_size(raster.cache) > 0
    end
  end

  describe "resize/2" do
    test "clears the grid so the next full payload repaints the new panel" do
      {raster, _} = Raster.apply(mono(), full_diff({4, 2}, [%Cell{symbol: "x"}]))
      resized = Raster.resize(raster, {36, 24})

      assert Raster.grid_size(resized) == {6, 3}
      assert Raster.grid(resized) == Grid.new()
      assert Raster.frame(resized) == :binary.copy(@paper, 36 * 24)
    end
  end

  describe "against a real CellSession" do
    test "text cells and a Viewport3D region land where the session put them" do
      raster = Raster.new(size: {240, 160}, format: XRGB8888, scale: 1)
      session = session(raster)

      widgets = [
        {%Paragraph{text: "hello"}, %Rect{x: 0, y: 0, width: 40, height: 1}},
        cube(%Rect{x: 10, y: 5, width: 20, height: 10})
      ]

      diff = draw(session, widgets)
      :ok = CellSession.close(session)

      assert [region] = diff.regions
      assert {region.x, region.y} == {11, 6}

      {raster, patches} = Raster.apply(raster, diff)
      assert Enum.any?(patches, &match?(%Patch{x: 66, y: 48, width: 108, height: 64}, &1))

      frame = Raster.frame(raster)
      assert byte_size(frame) == 240 * 160 * 4
      # "h" starts with an ink pixel in the default foreground on the default background.
      assert pixel(frame, raster, 0, 0) == <<229, 229, 229, 255>>
      assert pixel(frame, raster, 4, 0) == <<0, 0, 0, 255>>
    end

    test "an animated region repaints only the region" do
      raster = Raster.new(size: {240, 160}, format: RGB565)
      session = session(raster)
      rect = %Rect{x: 0, y: 0, width: 20, height: 10}

      {raster, _} = Raster.apply(raster, draw(session, [cube(rect, 0.2)]))
      {_raster, patches} = Raster.apply(raster, draw(session, [cube(rect, 0.9)]))
      :ok = CellSession.close(session)

      assert [%Patch{x: 6, y: 8, width: 108, height: 64}] = patches
    end

    test "a still region beside an animated one is rasterised once" do
      raster = Raster.new(size: {240, 160}, format: RGB565)
      session = session(raster)
      still = %Rect{x: 0, y: 0, width: 20, height: 10}
      turning = %Rect{x: 20, y: 0, width: 20, height: 10}

      {raster, first} =
        Raster.apply(raster, draw(session, [cube(still, 0.2), cube(turning, 0.2)]))

      {_raster, next} =
        Raster.apply(raster, draw(session, [cube(still, 0.2), cube(turning, 0.9)]))

      :ok = CellSession.close(session)

      assert Enum.count(first, &(&1.height == 64)) == 2
      assert [%Patch{x: 126, y: 8, width: 108, height: 64}] = next
    end
  end

  describe "rotate:" do
    @angles [90, 180, 270]

    # Bold, reversed, colours, box glyphs, a braille glyph, a gray
    # background (a checkerboard on Mono): a bit of everything, on a grid
    # with a margin on both sides.
    @text_cells [
      %Cell{col: 0, row: 0, symbol: "A", fg: :red, bg: :blue},
      %Cell{col: 1, row: 0, symbol: "B", modifiers: [:bold]},
      %Cell{col: 2, row: 0, symbol: "C", modifiers: [:reversed]},
      %Cell{col: 0, row: 1, symbol: "┌"},
      %Cell{col: 1, row: 1, symbol: "─"},
      %Cell{col: 2, row: 1, symbol: "┐"},
      %Cell{col: 3, row: 2, symbol: "█", fg: {:rgb, 250, 10, 10}},
      %Cell{col: 4, row: 3, symbol: "⠇", fg: :green, bg: {:rgb, 128, 128, 128}},
      %Cell{col: 9, row: 4, symbol: "Z", fg: :yellow}
    ]

    # A gradient bitmap upscaled onto four cells, and a region that hangs
    # off the grid on both sides, so clipping and sampling both show.
    @regions [
      %Region{
        x: 1,
        y: 1,
        width: 2,
        height: 2,
        pixel_width: 2,
        pixel_height: 2,
        data: <<255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 0>>
      },
      %Region{
        x: 7,
        y: 3,
        width: 5,
        height: 4,
        pixel_width: 3,
        pixel_height: 2,
        data: <<10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120, 130, 140, 150, 160, 170, 180>>
      }
    ]

    # The same app image (61×41 logical, a 10×5 grid with a one-pixel margin
    # on the right and at the bottom) on a flat raster and on one turned by
    # `angle`. Odd × odd, so the panel's checkerboard phase agrees with the
    # app's whichever way it is turned (the anchoring test below uses an
    # even panel to tell them apart).
    defp pair(format, angle, logical \\ {61, 41}) do
      {lw, lh} = logical
      physical = if angle in [90, 270], do: {lh, lw}, else: logical
      flat = Raster.new(size: logical, format: format)
      turned = Raster.new(size: physical, format: format, rotate: angle)
      {flat, turned}
    end

    # The flat frame, rotated by hand, and the turned raster's frame and patches.
    defp turned_frames({flat, turned}, cells, regions) do
      diff = full_diff(Raster.grid_size(flat), cells, regions)
      {flat, _patches} = Raster.apply(flat, diff)
      {turned, patches} = Raster.apply(turned, diff)
      {lw, lh} = Raster.logical_size(turned)
      bpp = Raster.bytes_per_pixel(turned)
      expected = Rotation.rotate_frame(Raster.frame(flat), lw, lh, bpp, Raster.rotate(turned))
      {expected, Raster.frame(turned), patches, turned}
    end

    defp blank_frame(%Raster{} = raster) do
      {w, h} = Raster.size(raster)
      :binary.copy(raster.blank, w * h)
    end

    defp ink(frame), do: frame |> :binary.bin_to_list() |> Enum.count(&(&1 == 0))

    test "rejects anything but the four angles" do
      for angle <- [45, -90, "90", nil] do
        assert_raise ArgumentError, ~r/:rotate/, fn -> mono({24, 16}, rotate: angle) end
      end
    end

    test "swaps the grid at 90 and 270, reports the logical size, and survives a resize" do
      raster = mono({24, 16}, rotate: 90)
      assert Raster.size(raster) == {24, 16}
      assert Raster.logical_size(raster) == {16, 24}
      assert Raster.grid_size(raster) == {2, 3}
      assert Raster.margin(raster) == {4, 0}
      assert Raster.rotate(raster) == 90

      resized = Raster.resize(raster, {48, 32})
      assert Raster.rotate(resized) == 90
      assert Raster.logical_size(resized) == {32, 48}
      assert Raster.grid_size(resized) == {5, 6}

      assert Raster.grid_size(mono({24, 16}, rotate: 180)) == {4, 2}
      assert Raster.grid_size(mono({24, 16}, rotate: 270)) == {2, 3}
    end

    for format <- [Mono, RGB565, XRGB8888], angle <- @angles do
      test "cells at #{angle} on #{inspect(format)} equal the rotated flat frame, from frame/1 and from the patches" do
        {expected, frame, patches, turned} =
          unquote(format) |> pair(unquote(angle)) |> turned_frames(@text_cells, [])

        assert frame == expected
        assert blit(blank_frame(turned), turned, patches) == expected
      end
    end

    for format <- [RGB565, XRGB8888], angle <- @angles do
      test "regions at #{angle} on #{inspect(format)} equal the rotated flat frame" do
        {expected, frame, patches, turned} =
          unquote(format) |> pair(unquote(angle)) |> turned_frames(@text_cells, @regions)

        assert frame == expected
        assert blit(blank_frame(turned), turned, patches) == expected
      end
    end

    for angle <- @angles do
      test "Mono regions at #{angle}: the patches give the frame and the dither keeps its tone" do
        {flat, turned} = pair(Mono, unquote(angle))
        gray = region(1, 1, 4, 3, {128, 128, 128})
        diff = full_diff(Raster.grid_size(flat), @text_cells, [gray])

        {flat, _patches} = Raster.apply(flat, diff)
        {turned, patches} = Raster.apply(turned, diff)
        frame = Raster.frame(turned)

        assert blit(blank_frame(turned), turned, patches) == frame
        # 4×3 cells of 50% gray: the Bayer tiles land on other panel pixels,
        # so only the tile edges can differ.
        assert abs(ink(frame) - ink(Raster.frame(flat))) <= div(24 * 24, 20)
      end
    end

    for angle <- @angles do
      test "checkerboards and dither follow the panel's pixel grid, not the app's, at #{angle}" do
        # An even panel with margins on the app's right and bottom: at 90 and
        # 270 the app's (x + y) parity and the panel's disagree, and at every
        # angle the grid sits somewhere else on the panel.
        turned = mono({26, 17}, rotate: unquote(angle))
        {cols, rows} = Raster.grid_size(turned)
        gray = %Cell{symbol: " ", bg: {:rgb, 128, 128, 128}}
        assert {_fg, {:checker, even, odd}} = Mono.cell_paints(gray, turned.config)

        cells = for col <- 0..(cols - 1), row <- 0..(rows - 1), do: %{gray | col: col, row: row}
        {checked, _patches} = Raster.apply(turned, full_diff({cols, rows}, cells))
        checker = Raster.frame(checked)

        # A gray region over the whole grid dithers with the panel's Bayer
        # tile: every covered pixel is what the format packs at that panel
        # position, whichever way the app is turned.
        region = region(0, 0, cols, rows, {128, 128, 128})
        {dithered, _patches} = Raster.apply(turned, full_diff({cols, rows}, [], [region]))
        dither = Raster.frame(dithered)

        for x <- 0..25, y <- 0..16, Raster.cell_at(turned, {x, y}) != :outside do
          expected = if rem(x + y, 2) == 0, do: even, else: odd
          assert pixel(checker, turned, x, y) == expected, "checker #{x},#{y}"

          assert pixel(dither, turned, x, y) == Mono.rgb_pixel(128, 128, 128, x, y, turned.config),
                 "dither #{x},#{y}"
        end
      end
    end

    property "cell_at/2 maps every pixel of a cell's rect back to it, and only those" do
      check all(
              scale <- integer(1..2),
              rotate <- member_of([0, 90, 180, 270]),
              cols <- integer(1..4),
              rows <- integer(1..3),
              right <- integer(0..5),
              bottom <- integer(0..7)
            ) do
        logical = {cols * 6 * scale + right, rows * 8 * scale + bottom}
        {lw, lh} = logical
        size = if rotate in [90, 270], do: {lh, lw}, else: logical
        raster = mono(size, scale: scale, rotate: rotate)
        {width, height} = Raster.size(raster)
        {cell_w, cell_h} = Raster.font_size(raster)
        assert Raster.grid_size(raster) == {cols, rows}

        # Every cell's four corners, mapped to the panel by the moduledoc's
        # corner mapping, come back as that cell.
        for col <- 0..(cols - 1), row <- 0..(rows - 1) do
          {x0, y0} = {col * cell_w, row * cell_h}

          for {x, y} <- [
                {x0, y0},
                {x0 + cell_w - 1, y0},
                {x0, y0 + cell_h - 1},
                {x0 + cell_w - 1, y0 + cell_h - 1}
              ] do
            point =
              case rotate do
                0 -> {x, y}
                90 -> {width - 1 - y, x}
                180 -> {width - 1 - x, height - 1 - y}
                270 -> {y, height - 1 - x}
              end

            assert Raster.cell_at(raster, point) == {col, row}
          end
        end

        # Counting every panel pixel: each cell gets exactly its area, the
        # margins are outside, and nothing else exists.
        counts =
          Enum.frequencies(
            for x <- 0..(width - 1), y <- 0..(height - 1), do: Raster.cell_at(raster, {x, y})
          )

        assert Map.get(counts, :outside, 0) == width * height - cols * rows * cell_w * cell_h
        assert Enum.all?(Map.delete(counts, :outside), fn {_cell, n} -> n == cell_w * cell_h end)
        assert map_size(counts) - if(right + bottom > 0, do: 1, else: 0) == cols * rows
      end
    end

    for angle <- @angles do
      test "a real session's Viewport3D region (a bitmap at panel size) lands turned at #{angle}" do
        {flat, turned} = pair(XRGB8888, unquote(angle), {73, 66})
        session = session(flat)
        widgets = [cube(%Rect{x: 0, y: 1, width: 12, height: 6})]
        diff = draw(session, widgets)

        {flat, _patches} = Raster.apply(flat, diff)
        {turned, patches} = Raster.apply(turned, diff)
        frame = Raster.frame(turned)

        # The bordered viewport's region is the 10×4 cells inside the border,
        # (6, 16, 60, 32) in the app's pixels: a 32×60 rect at 90 and 270.
        assert Raster.size(turned) == if(unquote(angle) == 180, do: {73, 66}, else: {66, 73})

        {x, y, w, h} =
          case unquote(angle) do
            90 -> {18, 6, 32, 60}
            180 -> {7, 18, 60, 32}
            270 -> {16, 7, 32, 60}
          end

        assert Enum.any?(patches, &match?(%Patch{x: ^x, y: ^y, width: ^w, height: ^h}, &1))
        assert frame == Rotation.rotate_frame(Raster.frame(flat), 73, 66, 4, unquote(angle))
        assert blit(blank_frame(turned), turned, patches) == frame
      end
    end

    for angle <- @angles do
      test "a bitmap at panel size clipped by the grid edge lands turned at #{angle}" do
        # 2×2 cells of 12×16 pixels hanging one cell off the grid on both sides.
        {flat, turned} = pair(RGB565, unquote(angle), {61, 41})
        data = for y <- 0..15, x <- 0..11, into: <<>>, do: <<x * 20, y * 15, 128>>

        region = %Region{
          x: 9,
          y: 4,
          width: 2,
          height: 2,
          pixel_width: 12,
          pixel_height: 16,
          data: data
        }

        {expected, frame, patches, turned} = turned_frames({flat, turned}, @text_cells, [region])
        assert frame == expected
        assert blit(blank_frame(turned), turned, patches) == expected
      end
    end
  end

  describe "to_png/1" do
    # A minimal PNG reader: the chunks in order, each CRC checked, the
    # IDAT data inflated into scanlines with their filter byte.
    defp read_png(<<137, "PNG", 13, 10, 26, 10, chunks::binary>>) do
      chunks = read_chunks(chunks)
      [{"IHDR", <<w::32, h::32, 8, 2, 0, 0, 0>>} | rest] = chunks
      assert {"IEND", <<>>} = List.last(rest)
      data = rest |> Enum.filter(&(elem(&1, 0) == "IDAT")) |> Enum.map(&elem(&1, 1))
      raw = :zlib.uncompress(IO.iodata_to_binary(data))
      rows = for <<0, row::binary-size(w * 3) <- raw>>, do: row
      assert length(rows) == h
      {w, h, rows}
    end

    defp read_chunks(<<>>), do: []

    defp read_chunks(<<len::32, type::binary-4, data::binary-size(len), crc::32, rest::binary>>) do
      assert crc == :erlang.crc32([type, data])
      [{type, data} | read_chunks(rest)]
    end

    defp rgb_at(rows, x, y), do: rows |> Enum.at(y) |> binary_part(x * 3, 3)

    for format <- [Mono, RGB565, XRGB8888] do
      test "#{inspect(format)}: the panel's colours, at every pixel" do
        raster = Raster.new(size: {13, 9}, format: unquote(format))
        # Pure black and pure white: the same on every format, tone rules included.
        cells = [
          %Cell{symbol: "█", fg: {:rgb, 0, 0, 0}},
          %Cell{col: 1, symbol: " ", bg: {:rgb, 255, 255, 255}}
        ]

        {raster, _patches} = Raster.apply(raster, full_diff({2, 1}, cells))

        {13, 9, rows} = read_png(Raster.to_png(raster))

        assert rgb_at(rows, 0, 0) == <<0, 0, 0>>
        assert rgb_at(rows, 6, 0) == <<255, 255, 255>>

        frame = Raster.frame(raster)
        line = 13 * Raster.bytes_per_pixel(raster)

        expected =
          for <<row::binary-size(line) <- frame>>,
            do: unquote(format).unpack_row(row, raster.config)

        assert rows == expected
      end
    end

    test "is the physical panel on a rotated raster" do
      raster = mono({24, 16}, rotate: 90)
      assert {24, 16, _rows} = read_png(Raster.to_png(raster))
    end

    test "names the missing callback for a format without unpack_row/2" do
      raster = Raster.new(size: {12, 8}, format: RasterExRatatui.Test.Gray)

      assert_raise ArgumentError, ~r/Test.Gray does not implement unpack_row\/2/, fn ->
        Raster.to_png(raster)
      end
    end
  end

  describe "patches against frames" do
    property "writing apply/2's patches over the previous frame gives the next frame" do
      check all(
              format <- member_of([Mono, RGB565]),
              scale <- integer(1..2),
              rotate <- member_of([0, 90, 180, 270]),
              steps <- list_of(diff_step(), min_length: 1, max_length: 8),
              max_runs: 150
            ) do
        logical = {5 * 6 * scale + 1, 3 * 8 * scale + 2}
        size = if rotate in [90, 270], do: {elem(logical, 1), elem(logical, 0)}, else: logical
        raster = Raster.new(size: size, format: format, scale: scale, rotate: rotate)

        {raster, _} = Raster.apply(raster, full_diff({5, 3}, []))

        {sequential, _frame} =
          Enum.reduce(steps, {raster, Raster.frame(raster)}, fn diff, {raster, frame} ->
            {raster, patches} = Raster.apply(raster, diff)

            next = Raster.frame(raster)
            assert blit(frame, raster, patches) == next
            {raster, next}
          end)

        # The same steps as one list: one set of patches, the same final frame.
        {batched, patches} = Raster.apply(raster, steps)
        assert blit(Raster.frame(raster), batched, patches) == Raster.frame(sequential)
      end
    end
  end

  defp diff_step do
    colors = member_of([:reset, :black, :red, {:rgb, 128, 128, 128}, {:rgb, 250, 10, 10}])

    cell =
      gen all(
            col <- integer(0..4),
            row <- integer(0..2),
            symbol <- member_of(["A", "█", "▀", " ", "⠇", "中"]),
            fg <- colors,
            bg <- colors,
            modifiers <- member_of([[], [:reversed], [:bold]]),
            skip <- boolean()
          ) do
        %Cell{
          col: col,
          row: row,
          symbol: symbol,
          fg: fg,
          bg: bg,
          modifiers: modifiers,
          skip: skip
        }
      end

    random_region =
      gen all(
            x <- integer(0..5),
            y <- integer(0..3),
            w <- integer(0..3),
            h <- integer(1..2),
            pw <- integer(0..3),
            ph <- integer(1..3),
            shade <- integer(0..255)
          ) do
        region(x, y, w, h, {shade, 255 - shade, shade}, {pw, ph})
      end

    # Regions mostly come from a small pool that overlaps itself, so the same
    # region shows up in consecutive payloads (kept, reordered, uncovered).
    pool = [
      region(0, 0, 2, 2, {0, 0, 0}, {2, 2}),
      region(1, 1, 2, 2, {255, 255, 255}, {1, 1}),
      region(1, 0, 3, 1, {120, 130, 140}, {3, 1}),
      region(3, 1, 2, 2, {250, 10, 10}, {2, 3}),
      region(4, 0, 1, 1, {10, 250, 10}, {1, 1})
    ]

    region = frequency([{4, member_of(pool)}, {1, random_region}])
    cells = list_of(cell, max_length: 8)
    regions = list_of(region, max_length: 3)

    # Mostly incremental diffs, sometimes a full payload, sometimes a full
    # payload at another size (as after a resize).
    frequency([
      {6,
       gen(all(ops <- cells, rs <- regions),
         do: %Diff{width: 5, height: 3, ops: ops, regions: rs}
       )},
      {1, gen(all(ops <- cells, rs <- regions), do: full_diff({5, 3}, ops, rs))},
      {1,
       gen(all(ops <- cells, rs <- regions),
         do: full_diff({4, 3}, Enum.filter(ops, &(&1.col < 4)), rs)
       )}
    ])
  end
end
