defmodule RasterExRatatui.Test.App do
  @moduledoc false
  use ExRatatui.App, runtime: :reducer

  alias ExRatatui.Event.Key
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Widgets.Paragraph
  alias RasterExRatatui.Test.Frames

  # `notify:` gets `{:mounted, opts}` on every mount; `mount_counter:` (an
  # Agent holding an integer) makes every mount after the first fail.
  @impl true
  def init(opts) do
    if pid = Keyword.get(opts, :notify), do: send(pid, {:mounted, opts})

    state = %{
      text: Keyword.get(opts, :text, "hi"),
      cube: Keyword.get(opts, :cube, false),
      hang_terminate: Keyword.get(opts, :hang_terminate, false),
      notify: Keyword.get(opts, :notify)
    }

    case Keyword.get(opts, :mount_counter) do
      nil ->
        {:ok, state}

      agent ->
        if Agent.get_and_update(agent, &{&1, &1 + 1}) == 0,
          do: {:ok, state},
          else: {:error, :no_remount}
    end
  end

  @impl true
  def update({:event, %Key{code: "!"}}, _state), do: raise("boom")
  def update({:event, %Key{code: "q"}}, state), do: {:stop, state}

  def update({:event, %Key{code: code}}, state),
    do: {:noreply, %{state | text: state.text <> code}}

  # Mouse events go back to whoever asked to be notified.
  def update({:event, %ExRatatui.Event.Mouse{} = mouse}, %{notify: pid} = state)
      when is_pid(pid) do
    send(pid, {:mouse, mouse})
    {:noreply, state, render?: false}
  end

  def update(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{hang_terminate: true}), do: Process.sleep(:infinity)
  def terminate(_reason, _state), do: :ok

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
    cond do
      Keyword.has_key?(opts, :init_stop) ->
        {:stop, Keyword.fetch!(opts, :init_stop)}

      Keyword.has_key?(opts, :init_return) ->
        Keyword.fetch!(opts, :init_return)

      true ->
        state = %{
          test_pid: Keyword.fetch!(opts, :test_pid),
          push_delay: Keyword.get(opts, :push_delay, 0)
        }

        {:ok, [size: Keyword.get(opts, :size, {240, 160})], state}
    end
  end

  @impl true
  def push(pixels, state) do
    send(state.test_pid, {:pushed, pixels})
    Process.sleep(state.push_delay)
    state
  end

  @impl true
  def handle_info({:keys, codes}, state) do
    {:events, Enum.map(codes, &%ExRatatui.Event.Key{code: &1, kind: "press"}), state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(reason, state), do: send(state.test_pid, {:terminated, reason})
end
