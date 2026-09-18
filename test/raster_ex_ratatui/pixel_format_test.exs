defmodule RasterExRatatui.PixelFormatTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Bitwise

  alias ExRatatui.CellSession.Cell
  alias RasterExRatatui.Palette
  alias RasterExRatatui.PixelFormat
  alias RasterExRatatui.PixelFormat.{Mono, RGB565, XRGB8888}

  doctest Palette
  doctest PixelFormat
  doctest Mono
  doctest RGB565
  doctest XRGB8888

  @ink <<0>>
  @paper <<255>>
  @gray {:checker, <<0>>, <<255>>}

  describe "Palette" do
    test "rejects theme keys that are not named colours" do
      assert_raise ArgumentError, ~r/unknown theme colours: \[:orange\]/, fn ->
        Palette.new(theme: %{orange: {255, 165, 0}})
      end
    end

    test "resolves every named colour and indexed 0..15 through the theme" do
      palette = Palette.new(theme: %{light_cyan: {1, 2, 3}})

      names =
        ~w(black red green yellow blue magenta cyan gray dark_gray light_red light_green light_yellow light_blue light_magenta light_cyan white)a

      for {name, index} <- Enum.with_index(names) do
        assert Palette.rgb(name, :fg, palette) == Palette.rgb({:indexed, index}, :bg, palette)
      end

      assert Palette.rgb({:indexed, 14}, :fg, palette) == {1, 2, 3}
    end

    test "the colour cube and grayscale ramp cover their ends" do
      assert Palette.rgb({:indexed, 16}, :fg) == {0, 0, 0}
      assert Palette.rgb({:indexed, 231}, :fg) == {255, 255, 255}
      assert Palette.rgb({:indexed, 232}, :fg) == {8, 8, 8}
      assert Palette.rgb({:indexed, 255}, :fg) == {238, 238, 238}
    end

    test "bold brightens only when bold_bright is on, and only dark named colours" do
      bold = %Cell{fg: :green, bg: :reset, modifiers: [:bold]}

      assert {{0, 255, 0}, _} = Palette.cell_colors(bold, Palette.new())
      assert {{0, 205, 0}, _} = Palette.cell_colors(bold, Palette.new(bold_bright: false))
      assert {{9, 9, 9}, _} = Palette.cell_colors(%{bold | fg: {:rgb, 9, 9, 9}}, Palette.new())
      assert Palette.bright(:light_green) == :light_green
      assert Palette.bright({:indexed, 8}) == {:indexed, 8}
    end
  end

  describe "Mono.cell_paints/2 (the badge tone rules)" do
    setup do
      %{config: Mono.init([])}
    end

    test "RGB colours threshold by luma into ink, gray, and paper", %{config: config} do
      assert Mono.cell_paints(%Cell{fg: {:rgb, 0, 0, 0}, bg: {:rgb, 255, 255, 255}}, config) ==
               {@ink, @paper}

      assert Mono.cell_paints(%Cell{fg: {:rgb, 240, 240, 240}, bg: {:rgb, 10, 10, 20}}, config) ==
               {@paper, @ink}

      assert Mono.cell_paints(%Cell{fg: {:rgb, 128, 128, 128}, bg: {:rgb, 128, 128, 128}}, config) ==
               {@gray, @gray}
    end

    test "the luma band edges are configurable and inclusive", %{config: config} do
      assert {@ink, _} = Mono.cell_paints(%Cell{fg: {:rgb, 76, 76, 76}}, config)
      assert {@paper, _} = Mono.cell_paints(%Cell{fg: {:rgb, 178, 178, 178}}, config)

      narrow = Mono.init(ink_max: 10, paper_min: 20)
      assert {@gray, _} = Mono.cell_paints(%Cell{fg: {:rgb, 15, 15, 15}}, narrow)
      assert {@paper, _} = Mono.cell_paints(%Cell{fg: {:rgb, 76, 76, 76}}, narrow)
    end

    test "black is ink on either side (Canvas :block and :half_block shapes)", %{config: config} do
      assert Mono.cell_paints(%Cell{fg: :black, bg: :black}, config) == {@ink, @ink}
      assert Mono.cell_paints(%Cell{fg: :black, bg: :reset}, config) == {@ink, @paper}
    end

    test "named and reset foregrounds contrast with the background tone", %{config: config} do
      assert Mono.cell_paints(%Cell{fg: :white}, config) == {@ink, @paper}
      assert Mono.cell_paints(%Cell{fg: :cyan, bg: :black}, config) == {@paper, @ink}
      assert Mono.cell_paints(%Cell{fg: :reset, bg: {:rgb, 0, 0, 0}}, config) == {@paper, @ink}

      assert Mono.cell_paints(%Cell{fg: {:indexed, 3}, bg: {:indexed, 200}}, config) ==
               {@ink, @paper}
    end

    test "bg: :white is plain paper, not an inversion", %{config: config} do
      assert Mono.cell_paints(%Cell{fg: :reset, bg: :white}, config) == {@ink, @paper}
    end

    test ":reversed always paints paper on ink", %{config: config} do
      for fg <- [:reset, :black, {:rgb, 0, 0, 0}],
          bg <- [:reset, :black, {:rgb, 255, 255, 255}] do
        assert Mono.cell_paints(%Cell{fg: fg, bg: bg, modifiers: [:reversed]}, config) ==
                 {@paper, @ink}
      end
    end
  end

  describe "Mono.rgb_pixel/6" do
    property "every pixel is ink or paper" do
      check all(
              r <- integer(0..255),
              g <- integer(0..255),
              b <- integer(0..255),
              x <- integer(0..1000),
              y <- integer(0..1000)
            ) do
        assert Mono.rgb_pixel(r, g, b, x, y, %{}) in [@ink, @paper]
      end
    end

    test "mid gray dithers to half ink over a 4×4 tile, and the tile repeats" do
      tile = for x <- 0..3, y <- 0..3, do: Mono.rgb_pixel(128, 128, 128, x, y, %{})
      shifted = for x <- 4..7, y <- 8..11, do: Mono.rgb_pixel(128, 128, 128, x, y, %{})

      assert Enum.count(tile, &(&1 == @ink)) == 8
      assert tile == shifted
    end
  end

  describe "rgb_row" do
    test "the fallback packs pixel by pixel with the right positions" do
      row = <<30, 30, 30, 60, 60, 60, 90, 90, 90>>
      assert PixelFormat.rgb_row(RasterExRatatui.Test.Gray, row, 5, 0, %{}) == <<35, 66, 97>>
      assert PixelFormat.rgb_row(RasterExRatatui.Test.Gray, <<>>, 5, 0, %{}) == <<>>
    end

    property "every built-in format's row equals its pixels" do
      check all(
              pixels <-
                list_of({integer(0..255), integer(0..255), integer(0..255)}, max_length: 12),
              x <- integer(0..7),
              y <- integer(0..7)
            ) do
        row = for {r, g, b} <- pixels, into: <<>>, do: <<r, g, b>>

        for {format, config} <- [{Mono, %{}}, {RGB565, Palette.new()}, {XRGB8888, Palette.new()}] do
          expected =
            pixels
            |> Enum.with_index(x)
            |> Enum.map_join(fn {{r, g, b}, px} -> format.rgb_pixel(r, g, b, px, y, config) end)

          assert format.rgb_row(row, x, y, config) == expected
          assert PixelFormat.rgb_row(format, row, x, y, config) == expected
        end
      end
    end
  end

  describe "RGB formats" do
    property "pack every colour to their width and round-trip within their precision" do
      check all(r <- integer(0..255), g <- integer(0..255), b <- integer(0..255)) do
        palette = Palette.new()

        assert <<^b, ^g, ^r, 255>> = XRGB8888.rgb_pixel(r, g, b, 0, 0, palette)

        <<value::little-16>> = RGB565.rgb_pixel(r, g, b, 0, 0, palette)
        assert value >>> 11 == r >>> 3
        assert (value >>> 5 &&& 0x3F) == g >>> 2
        assert (value &&& 0x1F) == b >>> 3
      end
    end

    test "cell paints and blank follow the palette" do
      palette = RGB565.init(reset_bg: {0, 0, 255}, theme: %{red: {255, 0, 0}})
      cell = %Cell{fg: :red, bg: :reset}

      assert RGB565.cell_paints(cell, palette) == {<<0, 248>>, <<31, 0>>}
      assert RGB565.blank(palette) == <<31, 0>>
      assert XRGB8888.cell_paints(cell, palette) == {<<0, 0, 255, 255>>, <<255, 0, 0, 255>>}
    end
  end
end
