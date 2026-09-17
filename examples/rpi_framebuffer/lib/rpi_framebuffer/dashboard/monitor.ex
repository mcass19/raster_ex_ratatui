defmodule RpiFramebuffer.Dashboard.Monitor do
  @moduledoc """
  The device at a glance, read straight from `/proc` and `/sys`: load and per-core CPU use, SoC temperature, memory, uptime, and the addresses the device answers on.

  Nothing here is Nerves-specific, so the tab shows the laptop's numbers when the dashboard runs in a terminal. A file that does not exist (no thermal zone, another OS) leaves its reading as `nil`, drawn as `n/a`.

  The tab samples once a second whether it is on screen or not, so its histories are already full when it is opened.

  ## Options

    * `:root` — filesystem root for `/proc` and `/sys`, default `"/"` (tests point it at a fake tree)
  """

  @behaviour RpiFramebuffer.Dashboard.Tab

  alias ExRatatui.Layout
  alias ExRatatui.Style
  alias ExRatatui.Subscription
  alias ExRatatui.Widgets.Block
  alias ExRatatui.Widgets.Gauge
  alias ExRatatui.Widgets.Paragraph
  alias ExRatatui.Widgets.Sparkline
  alias RpiFramebuffer.Dashboard.Showcase
  alias RpiFramebuffer.Dashboard.Tab

  @sample_ms 1_000
  @history 240

  # The temperature sparkline spans 30 to 90 °C, in tenths of a degree.
  @coolest 300
  @hottest 900

  @typedoc "Jiffies of one `/proc/stat` cpu line: `{busy, total}`."
  @type counters :: {non_neg_integer(), non_neg_integer()}

  @impl Tab
  def title, do: "System"

  @impl Tab
  def init(opts) do
    root = Keyword.get(opts, :root, "/")

    %{
      root: root,
      host: host(root),
      reading: read(root),
      cores: [],
      cpu: [],
      temperature: []
    }
  end

  @impl Tab
  def update({:info, :sample}, state), do: {:ok, record(state, read(state.root))}
  def update(_message, _state), do: :ignored

  @impl Tab
  def subscriptions(_state, _active?) do
    [Subscription.interval(:system_sample, @sample_ms, Tab.message(__MODULE__, :sample))]
  end

  @impl Tab
  def hints(_state), do: []

  @doc """
  Records a `reading`: CPU use is the change in the `/proc/stat` counters since the previous reading, per core and overall, and the overall figure and the temperature join their histories.
  """
  @spec record(map(), map()) :: map()
  def record(state, reading) do
    [total | cores] = usages(state.reading.stat, reading.stat)

    %{
      state
      | reading: reading,
        cores: cores,
        cpu: Tab.push(state.cpu, total, @history),
        temperature: push_known(state.temperature, reading.temperature)
    }
  end

  defp push_known(history, nil), do: history
  defp push_known(history, value), do: Tab.push(history, round(value * 10), @history)

  # The first counters are the aggregate "cpu" line. A reading without
  # /proc/stat, or with another core count, counts as idle.
  defp usages(old, new) when length(old) == length(new) and new != [] do
    old |> Enum.zip(new) |> Enum.map(fn {a, b} -> usage(a, b) end)
  end

  defp usages(_old, _new), do: [0]

  @doc """
  Reads every source under `root` once.
  """
  @spec read(Path.t()) :: map()
  def read(root) do
    %{
      stat: root |> file("proc/stat") |> parse_stat(),
      load: root |> file("proc/loadavg") |> parse_loadavg(),
      memory: root |> file("proc/meminfo") |> parse_meminfo(),
      uptime: root |> file("proc/uptime") |> parse_uptime(),
      temperature: root |> file("sys/class/thermal/thermal_zone0/temp") |> parse_temperature(),
      addresses: addresses()
    }
  end

  defp host(root) do
    %{
      name: String.trim(file(root, "proc/sys/kernel/hostname")),
      kernel: String.trim(file(root, "proc/sys/kernel/osrelease")),
      arch: List.to_string(:erlang.system_info(:system_architecture)),
      otp: List.to_string(:erlang.system_info(:otp_release)),
      elixir: System.version()
    }
  end

  defp file(root, path) do
    case File.read(Path.join(root, path)) do
      {:ok, contents} -> contents
      {:error, _reason} -> ""
    end
  end

  @doc """
  The `{busy, total}` jiffies of every `cpu` line of `/proc/stat`, the aggregate line first. Idle and iowait are the columns that do not count as busy.

  ## Examples

      iex> RpiFramebuffer.Dashboard.Monitor.parse_stat("cpu  10 0 10 70 10 0 0 0 0 0\\ncpu0 5 0 5 35 5 0 0 0 0 0\\nintr 1 2\\n")
      [{20, 100}, {10, 50}]

      iex> RpiFramebuffer.Dashboard.Monitor.parse_stat("")
      []
  """
  @spec parse_stat(String.t()) :: [counters()]
  def parse_stat(contents) do
    for line <- String.split(contents, "\n"),
        ["cpu" <> _index | fields] <- [String.split(line, " ", trim: true)] do
      jiffies = Enum.map(fields, &String.to_integer/1)
      total = Enum.sum(jiffies)
      {total - Enum.at(jiffies, 3, 0) - Enum.at(jiffies, 4, 0), total}
    end
  end

  @doc """
  CPU use between two counters, as a percentage.

  ## Examples

      iex> RpiFramebuffer.Dashboard.Monitor.usage({20, 100}, {70, 200})
      50

      iex> RpiFramebuffer.Dashboard.Monitor.usage({20, 100}, {20, 100})
      0
  """
  @spec usage(counters(), counters()) :: 0..100
  def usage({_busy, total}, {_new_busy, new_total}) when new_total <= total, do: 0

  def usage({busy, total}, {new_busy, new_total}) do
    (max(new_busy - busy, 0) * 100) |> div(new_total - total) |> min(100)
  end

  @doc """
  The 1, 5, and 15 minute load averages of `/proc/loadavg`, kept as text.

  ## Examples

      iex> RpiFramebuffer.Dashboard.Monitor.parse_loadavg("0.52 0.31 0.18 1/142 2203\\n")
      ["0.52", "0.31", "0.18"]

      iex> RpiFramebuffer.Dashboard.Monitor.parse_loadavg("")
      nil
  """
  @spec parse_loadavg(String.t()) :: [String.t()] | nil
  def parse_loadavg(contents) do
    case String.split(contents, " ", trim: true) do
      [one, five, fifteen | _rest] -> [one, five, fifteen]
      _too_short -> nil
    end
  end

  @doc """
  `{used, total}` in kB from `/proc/meminfo`, where used is what `MemAvailable` leaves.

  ## Examples

      iex> RpiFramebuffer.Dashboard.Monitor.parse_meminfo("MemTotal: 4000 kB\\nMemFree: 500 kB\\nMemAvailable: 3000 kB\\n")
      {1000, 4000}

      iex> RpiFramebuffer.Dashboard.Monitor.parse_meminfo("")
      nil
  """
  @spec parse_meminfo(String.t()) :: {non_neg_integer(), pos_integer()} | nil
  def parse_meminfo(contents) do
    fields =
      for line <- String.split(contents, "\n"),
          [key, value | _unit] <- [String.split(line, [":", " "], trim: true)],
          into: %{},
          do: {key, value}

    with %{"MemTotal" => total, "MemAvailable" => available} <- fields,
         {total, ""} when total > 0 <- Integer.parse(total),
         {available, ""} <- Integer.parse(available) do
      {max(total - available, 0), total}
    else
      _missing -> nil
    end
  end

  @doc """
  Whole seconds since boot, from `/proc/uptime`.

  ## Examples

      iex> RpiFramebuffer.Dashboard.Monitor.parse_uptime("3725.48 14000.12\\n")
      3725

      iex> RpiFramebuffer.Dashboard.Monitor.parse_uptime("")
      nil
  """
  @spec parse_uptime(String.t()) :: non_neg_integer() | nil
  def parse_uptime(contents) do
    case Integer.parse(contents) do
      {seconds, _rest} -> seconds
      :error -> nil
    end
  end

  @doc """
  Degrees Celsius from a thermal zone's `temp` file, which holds millidegrees.

  ## Examples

      iex> RpiFramebuffer.Dashboard.Monitor.parse_temperature("48312\\n")
      48.3

      iex> RpiFramebuffer.Dashboard.Monitor.parse_temperature("")
      nil
  """
  @spec parse_temperature(String.t()) :: float() | nil
  def parse_temperature(contents) do
    case Integer.parse(contents) do
      {millidegrees, _rest} -> Float.round(millidegrees / 1000, 1)
      :error -> nil
    end
  end

  @doc """
  The IPv4 addresses of every interface that is not the loopback, as `{interface, address}` strings.
  """
  @spec addresses() :: [{String.t(), String.t()}]
  def addresses do
    {:ok, interfaces} = :inet.getifaddrs()
    ipv4(interfaces)
  end

  @doc """
  The non-loopback IPv4 addresses in a `:inet.getifaddrs/0` list.

  ## Examples

      iex> RpiFramebuffer.Dashboard.Monitor.ipv4([
      ...>   {~c"lo", [flags: [:up, :loopback], addr: {127, 0, 0, 1}]},
      ...>   {~c"usb0", [flags: [:up], addr: {172, 31, 36, 97}, addr: {65152, 0, 0, 0, 1, 2, 3, 4}]},
      ...>   {~c"wlan0", [flags: []]}
      ...> ])
      [{"usb0", "172.31.36.97"}]
  """
  @spec ipv4([{charlist(), keyword()}]) :: [{String.t(), String.t()}]
  def ipv4(interfaces) do
    for {name, props} <- interfaces,
        :loopback not in Keyword.get(props, :flags, []),
        {:addr, {_a, _b, _c, _d} = address} <- props do
      {List.to_string(name), address |> :inet.ntoa() |> List.to_string()}
    end
  end

  @impl Tab
  def render(state, area) do
    if Tab.landscape?(area) do
      [left, right] = Layout.split(area, :horizontal, [{:fill, 1}, {:fill, 1}])
      [host, network] = Layout.split(left, :vertical, [{:length, 7}, {:fill, 1}])
      [cpu, vitals] = Layout.split(right, :vertical, [{:fill, 1}, {:length, 9}])
      widgets(state, host, cpu, vitals, network)
    else
      [host, cpu, vitals, network] =
        Layout.split(area, :vertical, [{:length, 7}, {:fill, 2}, {:length, 9}, {:fill, 1}])

      widgets(state, host, cpu, vitals, network)
    end
  end

  defp widgets(state, host, cpu, vitals, network) do
    host_widgets(state, host) ++
      cpu_widgets(state, cpu) ++
      vitals_widgets(state, vitals) ++
      network_widgets(state, network)
  end

  defp host_widgets(%{host: host, reading: reading}, area) do
    lines = [
      "host     #{blank(host.name)}",
      "kernel   #{blank(host.kernel)}",
      "arch     #{host.arch}",
      "runtime  Elixir #{host.elixir} on OTP #{host.otp}",
      "uptime   #{uptime(reading.uptime)}"
    ]

    [
      {pane(" Device ", :light_cyan), area},
      {%Paragraph{text: Enum.join(lines, "\n")}, Tab.inner(area)}
    ]
  end

  defp cpu_widgets(state, area) do
    inner = Tab.inner(area)
    cores = Enum.take(state.cores, div(inner.height, 2))

    [load, history | core_rects] =
      Layout.split(
        inner,
        :vertical,
        [{:length, 1}, {:fill, 1}] ++ Enum.map(cores, fn _core -> {:length, 1} end)
      )

    load_text =
      case state.reading.load do
        nil -> "load n/a"
        averages -> "load #{Enum.join(averages, " ")}   now #{List.last(state.cpu) || 0}%"
      end

    core_widgets =
      cores
      |> Enum.with_index()
      |> Enum.zip(core_rects)
      |> Enum.flat_map(fn {{percent, index}, rect} ->
        label = String.pad_trailing("cpu#{index}", 6) <> String.pad_leading("#{percent}%", 4)
        labelled(label, rect, fn _rect -> bar(percent / 100, heat(percent)) end)
      end)

    [
      {pane(" CPU ", :light_green), area},
      {%Paragraph{text: load_text}, load},
      {%Sparkline{data: Tab.fit(state.cpu, history), max: 100, style: %Style{fg: :light_green}},
       history}
    ] ++ core_widgets
  end

  defp vitals_widgets(state, area) do
    [memory, amount, temperature, history] =
      Layout.split(Tab.inner(area), :vertical, [
        {:length, 1},
        {:length, 1},
        {:length, 1},
        {:fill, 1}
      ])

    celsius = state.reading.temperature
    color = temperature_color(celsius)

    [{pane(" Memory and temperature ", :light_yellow), area}] ++
      labelled("memory", memory, fn _rect -> memory_bar(state.reading.memory) end) ++
      labelled("", amount, fn _rect -> %Paragraph{text: memory_text(state.reading.memory)} end) ++
      labelled("soc temp", temperature, fn _rect ->
        %Paragraph{text: temperature_text(celsius), style: %Style{fg: color}}
      end) ++
      labelled("", history, fn rect ->
        data = state.temperature |> Tab.fit(rect) |> Enum.map(&max(&1 - @coolest, 0))
        %Sparkline{data: data, max: @hottest - @coolest, style: %Style{fg: color}}
      end)
  end

  defp network_widgets(state, area) do
    text =
      case state.reading.addresses do
        [] ->
          "no address yet"

        addresses ->
          Enum.map_join(addresses, "\n", fn {name, ip} ->
            "#{String.pad_trailing(name, 8)} #{ip}"
          end)
      end

    [{pane(" Network ", :light_magenta), area}, {%Paragraph{text: text}, Tab.inner(area)}]
  end

  defp memory_bar(nil), do: %Paragraph{text: "n/a"}
  defp memory_bar({used, total}), do: bar(min(used / total, 1.0), :light_blue)

  defp memory_text(nil), do: ""
  defp memory_text({used, total}), do: "#{gigabytes(used)} of #{gigabytes(total)} GB used"

  # The numbers live in the text beside the bar: a label drawn over the bar
  # takes the bar's own colours and is hard to read on a small font.
  defp bar(ratio, color) do
    %Gauge{ratio: ratio, label: "", gauge_style: %Style{fg: color, bg: :dark_gray}}
  end

  defp gigabytes(kilobytes), do: :erlang.float_to_binary(kilobytes / 1_048_576, decimals: 1)

  defp heat(percent) when percent >= 85, do: :light_red
  defp heat(percent) when percent >= 60, do: :light_yellow
  defp heat(_percent), do: :light_green

  @doc """
  The colour for a SoC temperature: a Pi starts throttling at 80 °C.

  ## Examples

      iex> Enum.map([45.0, 68.2, 81.0, nil], &RpiFramebuffer.Dashboard.Monitor.temperature_color/1)
      [:light_green, :light_yellow, :light_red, :gray]
  """
  @spec temperature_color(float() | nil) :: atom()
  def temperature_color(nil), do: :gray
  def temperature_color(celsius) when celsius >= 75, do: :light_red
  def temperature_color(celsius) when celsius >= 60, do: :light_yellow
  def temperature_color(_celsius), do: :light_green

  defp temperature_text(nil), do: "n/a"
  defp temperature_text(celsius), do: "#{celsius} °C"

  defp uptime(nil), do: "n/a"
  defp uptime(seconds), do: Showcase.uptime(seconds * 1000)

  defp blank(""), do: "n/a"
  defp blank(text), do: text

  defp pane(title, color) do
    %Block{title: title, borders: [:all], border_type: :rounded, border_style: %Style{fg: color}}
  end

  defp labelled(label, area, widget) do
    [label_rect, widget_rect] = Layout.split(area, :horizontal, [{:length, 11}, {:fill, 1}])

    [
      {%Paragraph{text: label, style: %Style{fg: :gray}}, label_rect},
      {widget.(widget_rect), widget_rect}
    ]
  end
end
