defmodule RpiFramebuffer.Dashboard.Showcase do
  @moduledoc """
  What a terminal cannot show: a spinning, lit 3D object and a colour photo as real bitmaps at the panel's own resolution, next to a live BEAM readout made of ordinary cells.

  The surface creates the cell session with the raster's effective cell size, so `ExRatatui.Widgets.Viewport3D` and `ExRatatui.Widgets.Image` hand over RGB bitmaps (pixel regions) instead of half-block cells, and the pixel format packs them for the framebuffer. In a terminal (`RpiFramebuffer.run/0`) the same widgets fall back to whatever the terminal supports.

  The panes sit side by side on a landscape panel and stack on a portrait one.

  ## Photos

  `priv/photos/` holds 1280×960 JPEGs served by [Lorem Picsum](https://picsum.photos) from [Unsplash](https://unsplash.com/license) (free to use; the pane title credits the photographer anyway, in ASCII because the library font has no accented letters). To add one, drop it there and add it to `@photos`.

  ## Keys

  | Key     | Action                  |
  | ------- | ----------------------- |
  | `s`     | Next 3D object          |
  | `p`     | Next photo              |
  | `space` | Pause or resume turning |

  ## Options

    * `:spin_ms` — milliseconds between two turns of the object, default `200`. Every turn re-renders the 3D region, so this is the knob for a slow panel.
  """

  @behaviour RpiFramebuffer.Dashboard.Tab

  alias ExRatatui.Event.Key
  alias ExRatatui.Image
  alias ExRatatui.Layout
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Style
  alias ExRatatui.Subscription
  alias ExRatatui.ThreeD.Camera
  alias ExRatatui.ThreeD.Light
  alias ExRatatui.ThreeD.Material
  alias ExRatatui.ThreeD.Mesh
  alias ExRatatui.ThreeD.Object
  alias ExRatatui.ThreeD.Scene
  alias ExRatatui.ThreeD.Transform
  alias ExRatatui.Widgets.Block
  alias ExRatatui.Widgets.Gauge
  alias ExRatatui.Widgets.Paragraph
  alias ExRatatui.Widgets.Sparkline
  alias ExRatatui.Widgets.Viewport3D
  alias RpiFramebuffer.Dashboard.Tab

  @spin_ms 200
  @sample_ms 1_000
  @step :math.pi() / 48
  @history 240
  @shapes [:cube, :orbit, :cylinder]
  @black {0, 0, 0}
  @white {255, 255, 255}
  @warm {255, 244, 214}

  @photos [
    {"jellyfish.jpg", "Marat Gilyadzinov"},
    {"canyon.jpg", "Alexey Topolyanskiy"},
    {"bear.jpg", "Thomas Lefebvre"},
    {"puppy.jpg", "Andre Spieker"}
  ]

  @impl Tab
  def title, do: "Showcase"

  @impl Tab
  def init(opts) do
    dir = Application.app_dir(:rpi_framebuffer, "priv/photos")

    photos =
      Enum.map(@photos, fn {file, author} ->
        {:ok, image} =
          dir |> Path.join(file) |> File.read!() |> Image.new(background: @black)

        {image, author}
      end)

    %{
      shape: :cube,
      angle: 0.0,
      paused?: false,
      spin_ms: Keyword.get(opts, :spin_ms, @spin_ms),
      photos: photos,
      photo: 0,
      stats: sample(),
      reductions: [],
      memory: []
    }
  end

  @impl Tab
  def update({:event, %Key{code: "s", kind: "press"}}, state),
    do: {:ok, %{state | shape: next_shape(state.shape)}}

  def update({:event, %Key{code: "p", kind: "press"}}, state),
    do: {:ok, %{state | photo: rem(state.photo + 1, length(state.photos))}}

  def update({:event, %Key{code: " ", kind: "press"}}, state),
    do: {:ok, %{state | paused?: not state.paused?}}

  def update({:info, :spin}, state), do: {:ok, %{state | angle: state.angle + @step}}
  def update({:info, :sample}, state), do: {:ok, record(state, sample())}
  def update(_message, _state), do: :ignored

  @impl Tab
  def subscriptions(_state, false), do: []

  def subscriptions(state, true) do
    sample = Subscription.interval(:showcase_sample, @sample_ms, Tab.message(__MODULE__, :sample))
    spin = Subscription.interval(:showcase_spin, state.spin_ms, Tab.message(__MODULE__, :spin))

    if state.paused?, do: [sample], else: [sample, spin]
  end

  @impl Tab
  def hints(state) do
    [{"s", "shape"}, {"p", "photo"}, {"space", if(state.paused?, do: "resume", else: "pause")}]
  end

  @doc """
  Records a VM `sample`: the reductions since the previous one and the total memory join their histories.
  """
  @spec record(map(), map()) :: map()
  def record(state, sample) do
    delta = max(sample.reductions - state.stats.reductions, 0)

    %{
      state
      | stats: sample,
        reductions: Tab.push(state.reductions, delta, @history),
        memory: Tab.push(state.memory, div(sample.memory, 1024), @history)
    }
  end

  @doc """
  The 3D object after `shape` in the cycle.

  ## Examples

      iex> Enum.map([:cube, :orbit, :cylinder], &RpiFramebuffer.Dashboard.Showcase.next_shape/1)
      [:orbit, :cylinder, :cube]
  """
  @spec next_shape(atom()) :: atom()
  def next_shape(shape) do
    index = Enum.find_index(@shapes, &(&1 == shape))
    Enum.at(@shapes, rem(index + 1, length(@shapes)))
  end

  @impl Tab
  def render(state, area) do
    [panes, beam] = Layout.split(area, :vertical, [{:fill, 1}, {:length, 13}])
    direction = if Tab.landscape?(panes), do: :horizontal, else: :vertical
    [first, second] = Layout.split(panes, direction, [{:fill, 1}, {:fill, 1}])
    {image, author} = Enum.at(state.photos, state.photo)

    viewport = %Viewport3D{
      scene: scene(state.shape, state.angle),
      camera: camera(state.shape),
      render_mode: :auto
    }

    [
      {pane(" 3D #{state.shape} ", :light_cyan), first},
      {viewport, Tab.inner(first)},
      {pane(" #{author} / Unsplash ", :light_yellow), second},
      {image, second |> Tab.inner() |> photo_rect()}
    ] ++ beam_widgets(state, beam)
  end

  @doc """
  The largest centred rect inside `area` with the photos' 4:3 shape. A cell of the library font is 6×8 pixels, so 4:3 in pixels is 16:9 in cells. The image widget anchors a fitted picture to the top left; handing it a rect of its own shape centres it.

  ## Examples

      iex> RpiFramebuffer.Dashboard.Showcase.photo_rect(%ExRatatui.Layout.Rect{x: 1, y: 40, width: 58, height: 30})
      %ExRatatui.Layout.Rect{x: 3, y: 40, width: 53, height: 30}

      iex> RpiFramebuffer.Dashboard.Showcase.photo_rect(%ExRatatui.Layout.Rect{x: 0, y: 0, width: 32, height: 30})
      %ExRatatui.Layout.Rect{x: 0, y: 6, width: 32, height: 18}
  """
  @spec photo_rect(Rect.t()) :: Rect.t()
  def photo_rect(%Rect{width: width, height: height} = area) do
    rows = min(height, div(width * 9, 16))
    cols = min(width, div(rows * 16, 9))

    %Rect{
      x: area.x + div(width - cols, 2),
      y: area.y + div(height - rows, 2),
      width: cols,
      height: rows
    }
  end

  defp pane(title, color) do
    %Block{title: title, borders: [:all], border_type: :rounded, border_style: %Style{fg: color}}
  end

  defp beam_widgets(state, area) do
    [stats, _gap, reductions, memory, gauge] =
      Layout.split(Tab.inner(area), :vertical, [
        {:length, 1},
        {:length, 1},
        {:fill, 1},
        {:fill, 1},
        {:length, 1}
      ])

    %{stats: sample} = state
    ratio = if sample.memory > 0, do: min(sample.process_memory / sample.memory, 1.0), else: 0.0

    [
      {pane(" BEAM ", :light_magenta), area},
      {%Paragraph{text: stats_text(sample)}, stats}
    ] ++
      labelled("reductions", reductions, fn rect ->
        %Sparkline{data: Tab.fit(state.reductions, rect), style: %Style{fg: :light_green}}
      end) ++
      labelled("memory", memory, fn rect ->
        data = state.memory |> Tab.fit(rect) |> above_minimum()
        %Sparkline{data: data, style: %Style{fg: :light_blue}}
      end) ++
      labelled("proc mem", gauge, fn _rect ->
        %Gauge{
          ratio: ratio,
          label: "#{round(ratio * 100)}%",
          gauge_style: %Style{fg: :light_magenta, bg: :dark_gray}
        }
      end)
  end

  defp labelled(label, area, widget) do
    [label_rect, widget_rect] = Layout.split(area, :horizontal, [{:length, 11}, {:fill, 1}])

    [
      {%Paragraph{text: label, style: %Style{fg: :gray}}, label_rect},
      {widget.(widget_rect), widget_rect}
    ]
  end

  defp stats_text(sample) do
    memory_mb = :erlang.float_to_binary(sample.memory / 1_048_576, decimals: 1)

    "procs #{sample.processes}   mem #{memory_mb} MB   run queue #{sample.run_queue}   up #{uptime(sample.uptime_ms)}"
  end

  @doc """
  Milliseconds as `HH:MM:SS`.

  ## Examples

      iex> RpiFramebuffer.Dashboard.Showcase.uptime(3_725_000)
      "01:02:05"
  """
  @spec uptime(non_neg_integer()) :: String.t()
  def uptime(milliseconds) do
    seconds = div(milliseconds, 1000)

    [div(seconds, 3600), rem(div(seconds, 60), 60), rem(seconds, 60)]
    |> Enum.map_join(":", &String.pad_leading(Integer.to_string(&1), 2, "0"))
  end

  @doc """
  The scene for `shape` turned by `angle` radians.
  """
  @spec scene(atom(), float()) :: Scene.t()
  def scene(shape, angle) do
    %Scene{
      objects: objects(shape, angle),
      lights: [
        Light.ambient(@white, 0.45),
        # The renderer's cube and sphere meshes disagree on which way their
        # normals face, so one key light leaves one of them lit from behind.
        # The same light from both sides brightens the top of either.
        Light.directional({-0.5, -1.0, -0.6}, @warm),
        Light.directional({0.5, 1.0, 0.6}, @warm),
        Light.point({2.5, 0.5, 1.0}, {90, 140, 255}, intensity: 1.5)
      ],
      background: @black
    }
  end

  defp objects(:cube, angle) do
    [
      %Object{
        mesh: Mesh.cube(),
        material: material({255, 140, 40}),
        transform: rotation(angle * 0.6, angle, 0.0)
      }
    ]
  end

  defp objects(:cylinder, angle) do
    [
      %Object{
        mesh: Mesh.cylinder(),
        material: material({220, 60, 160}),
        transform: %Transform{rotation(angle, 0.0, angle * 0.5) | scale: {1.2, 1.6, 1.2}}
      }
    ]
  end

  defp objects(:orbit, angle) do
    radius = 1.3

    [
      %Object{
        mesh: Mesh.sphere(),
        material: material({40, 190, 170}),
        transform: %Transform{scale: {1.3, 1.3, 1.3}}
      },
      %Object{
        mesh: Mesh.cube(),
        material: material({255, 200, 60}),
        transform: %Transform{
          rotation(angle, angle, 0.0)
          | position: {radius * :math.cos(angle), 0.35, radius * :math.sin(angle)},
            scale: {0.45, 0.45, 0.45}
        }
      }
    ]
  end

  defp material(color), do: %Material{color: color, ambient: 0.4, specular: 0.6}

  defp rotation(x, y, z), do: %Transform{rotation: {:euler_xyz, {x, y, z}}}

  defp camera(:orbit), do: %Camera{position: {2.2, 1.8, 3.2}, target: {0.0, 0.0, 0.0}}
  defp camera(_shape), do: %Camera{position: {1.5, 1.25, 2.0}, target: {0.0, 0.0, 0.0}}

  # Memory moves by a few percent at most; plotting it above its own minimum
  # makes the trend visible instead of a solid block.
  defp above_minimum([]), do: []

  defp above_minimum(history) do
    minimum = Enum.min(history)
    Enum.map(history, &(&1 - minimum))
  end

  defp sample do
    {reductions, _since_last_call} = :erlang.statistics(:reductions)
    {uptime_ms, _since_last_call} = :erlang.statistics(:wall_clock)

    %{
      processes: :erlang.system_info(:process_count),
      memory: :erlang.memory(:total),
      process_memory: :erlang.memory(:processes),
      reductions: reductions,
      run_queue: :erlang.statistics(:total_run_queue_lengths),
      uptime_ms: uptime_ms
    }
  end
end
