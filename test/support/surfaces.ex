defmodule RasterExRatatui.Test.App do
  @moduledoc false
  use ExRatatui.App, runtime: :reducer

  alias ExRatatui.Event.Key
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Widgets.Paragraph
  alias RasterExRatatui.Test.Frames

  @impl true
  def init(opts) do
    {:ok, %{text: Keyword.get(opts, :text, "hi"), cube: Keyword.get(opts, :cube, false)}}
  end

  @impl true
  def update({:event, %Key{code: "!"}}, _state), do: raise("boom")
  def update({:event, %Key{code: "q"}}, state), do: {:stop, state}

  def update({:event, %Key{code: code}}, state),
    do: {:noreply, %{state | text: state.text <> code}}

  def update(_msg, state), do: {:noreply, state}

  @impl true
  def render(state, frame) do
    text = {%Paragraph{text: state.text}, %Rect{x: 0, y: 0, width: frame.width, height: 1}}

    if state.cube do
      [text, Frames.cube(%Rect{x: 0, y: 1, width: 12, height: 6})]
    else
      [text]
    end
  end
end

defmodule RasterExRatatui.Test.FailingApp do
  @moduledoc false
  use ExRatatui.App, runtime: :reducer

  @impl true
  def init(_opts), do: {:error, :no_mount}

  @impl true
  def update(_msg, state), do: {:noreply, state}

  @impl true
  def render(_state, _frame), do: []
end

defmodule RasterExRatatui.Test.Surface do
  @moduledoc false
  use RasterExRatatui.Surface,
    app: RasterExRatatui.Test.App,
    format: RasterExRatatui.PixelFormat.Mono

  @impl true
  def init(opts) do
    case Keyword.fetch(opts, :init_stop) do
      {:ok, reason} ->
        {:stop, reason}

      :error ->
        {:ok, [size: Keyword.get(opts, :size, {240, 160})], Keyword.fetch!(opts, :test_pid)}
    end
  end

  @impl true
  def push(pixels, test_pid) do
    send(test_pid, {:pushed, pixels})
    test_pid
  end

  @impl true
  def handle_info({:keys, codes}, test_pid) do
    {:events, Enum.map(codes, &%ExRatatui.Event.Key{code: &1, kind: "press"}), test_pid}
  end

  def handle_info(_msg, test_pid), do: {:noreply, test_pid}

  @impl true
  def terminate(reason, test_pid), do: send(test_pid, {:terminated, reason})
end
