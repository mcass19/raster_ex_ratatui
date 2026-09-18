defmodule RasterExRatatui.RasterTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import RasterExRatatui.Test.Frames

  alias ExRatatui.CellSession
  alias ExRatatui.CellSession.{Cell, Diff, Snapshot}
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Widgets.Paragraph
  alias RasterExRatatui.Font.{Art, Default6x8}
  alias RasterExRatatui.{Grid, Patch, Raster}
  alias RasterExRatatui.PixelFormat.{Mono, RGB565, XRGB8888}

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

  describe "patches against frames" do
    property "writing apply/2's patches over the previous frame gives the next frame" do
      check all(
              format <- member_of([Mono, RGB565]),
              scale <- integer(1..2),
              steps <- list_of(diff_step(), min_length: 1, max_length: 8),
              max_runs: 150
            ) do
        raster =
          Raster.new(size: {5 * 6 * scale + 1, 3 * 8 * scale + 2}, format: format, scale: scale)

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
