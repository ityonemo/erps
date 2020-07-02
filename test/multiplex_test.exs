defmodule ErpsTest.MultiplexTest do

  # Tests that long-runnning tasks can be multiplexed over an Erps Connection.

  use ExUnit.Case, async: true

  @moduletag :erps

  alias Erps.Daemon

  defmodule Client do
    use Erps.Client

    @localhost IP.localhost()

    def start_link(port) do
      Erps.Client.start_link(__MODULE__, :ok, server: @localhost, port: port)
    end

    def init(initial_state), do: {:ok, initial_state}

    def sleep_for(client, time), do: GenServer.call(client, {:sleepfor, time})

  end

  defmodule Server do
    use Erps.Server

    def start_link(state, opts) do
      Erps.Server.start_link(__MODULE__, state, opts)
    end

    def init(_test_pid), do: {:ok, nil}

    def handle_call({:sleepfor, time}, from, state) do
      Task.start(fn ->
        Process.sleep(time)
        GenServer.reply(from, {:slept, time})
      end)

      {:noreply, state}
    end
  end

  test "multiplexing tasks" do
    test_pid = self()
    {:ok, daemon} = Daemon.start_link(Server, self())
    {:ok, port} = Daemon.port(daemon)
    {:ok, client} = Client.start_link(port)

    Process.sleep(20)

    # establish an "outer task" which is a call over the
    # client.  This should not block the communications
    # channel.
    Task.start(fn ->
      send(test_pid, Client.sleep_for(client, 500))
    end)

    Process.sleep(100)

    # establish an "inner task" which should not be blocked
    # by completion of the outer task.
    Task.start(fn ->
      send(test_pid, Client.sleep_for(client, 200))
    end)

    assert_receive {:slept, 200}, 300
    refute_received {:slept, 500}

    assert_receive {:slept, 500}, 300

    Process.sleep(1000)
  end
end
