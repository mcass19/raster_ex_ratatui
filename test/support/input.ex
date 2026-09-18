defmodule RasterExRatatui.Test.Input do
  @moduledoc false

  # Stands in for `InputEvent` inside the calling process: the devices to
  # enumerate live in the process dictionary, a reader is a linked process
  # that waits to be stopped, and every call is reported to the caller.
  # `RasterExRatatui.Input.Devices` is process-less and is driven from the
  # test process, so `self()` is the test.

  def devices(list), do: Process.put({__MODULE__, :devices}, list)

  def fail_next(reason), do: Process.put({__MODULE__, :fail}, reason)

  def enumerate do
    send(self(), :enumerated)
    Process.get({__MODULE__, :devices}, [])
  end

  def start_link(opts) do
    case Process.delete({__MODULE__, :fail}) do
      nil ->
        reader = spawn_link(fn -> receive(do: (:stop -> :ok)) end)
        send(self(), {:reader, reader, opts})
        {:ok, reader}

      reason ->
        {:error, reason}
    end
  end

  def stop(reader) do
    send(reader, :stop)
    send(self(), {:stopped, reader})
    :ok
  end
end
