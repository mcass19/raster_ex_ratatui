defmodule RasterExRatatui.Test.Input do
  @moduledoc false

  # Stands in for `InputEvent`. The devices to enumerate live in the
  # process dictionary of the test that set them with `devices/1`; a reader
  # is a process linked to the caller that waits to be stopped; every call
  # is reported to that test.
  #
  # `RasterExRatatui.Input.Devices` is process-less, so in its own tests
  # the caller is the test. Under a surface the caller is the surface
  # process, and the test is found through `$callers` (start_supervised)
  # or `$ancestors` (start_link): the first one whose dictionary holds a
  # device list.

  @key {__MODULE__, :devices}

  def devices(list), do: Process.put(@key, list)

  def fail_next(reason), do: Process.put({__MODULE__, :fail}, reason)

  def enumerate do
    owner = owner()
    send(owner, :enumerated)
    devices_of(owner)
  end

  def start_link(opts) do
    owner = owner()

    case Process.delete({__MODULE__, :fail}) do
      nil ->
        reader = spawn_link(fn -> receive(do: (:stop -> :ok)) end)
        send(owner, {:reader, reader, opts})
        {:ok, reader}

      reason ->
        {:error, reason}
    end
  end

  def stop(reader) do
    send(reader, :stop)
    send(owner(), {:stopped, reader})
    :ok
  end

  defp owner do
    if Process.get(@key) do
      self()
    else
      (Process.get(:"$callers", []) ++ Process.get(:"$ancestors", []))
      |> Enum.filter(&is_pid/1)
      |> Enum.find(self(), &(devices_of(&1) != nil))
    end
  end

  defp devices_of(pid) when pid == self(), do: Process.get(@key)

  defp devices_of(pid) do
    with {:dictionary, dict} <- Process.info(pid, :dictionary),
         {@key, list} <- List.keyfind(dict, @key, 0) do
      list
    else
      _none -> nil
    end
  end
end
