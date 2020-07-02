defmodule ErpsTest.MultiverseTest do
  use ExUnit.Case, async: true

  alias Erps.Daemon

  defmodule Server do
    use Erps.Server

    require Multiverses

    def start_link(test_pid, opts) do
      # make sure that forward_callers is coming from the daemon.
      if opts[:forward_callers] do
        Erps.Server.start_link(__MODULE__, test_pid, opts)
      else
        {:error, :invalid}
      end
    end

    def init(test_pid), do: {:ok, test_pid}

    def handle_call(:server_universe, _, test_pid) do
      {:reply, Multiverses.self(), test_pid}
    end
  end

  defmodule Client do
    use Erps.Client

    require Multiverses

    @localhost IP.localhost()

    def start_link(test_pid, port) do
      Erps.Client.start_link(__MODULE__, test_pid, server: @localhost, port: port, forward_callers: true)
    end
    def init(test_pid) do
      send(test_pid, {:client_universe, Multiverses.self()})
      {:ok, test_pid}
    end
  end

  test "servers and clients get instantiated with the correct $callers value." do
    test_pid = self()
    {:ok, daemon} = Daemon.start_link(Server, test_pid, forward_callers: true)
    {:ok, port} = Daemon.port(daemon)
    {:ok, client_pid} = Client.start_link(test_pid, port)

    assert_receive {:client_universe, ^test_pid}

    assert test_pid == GenServer.call(client_pid, :server_universe)
  end

  test "servers get the correct $callers value when supervised." do
    test_pid = self()
    spawn_link fn ->
      {:ok, sup} = DynamicSupervisor.start_link(strategy: :one_for_one)
      send(test_pid, {:sup, sup})

      receive do :never -> :die end
    end

    sup = receive do {:sup, sup} -> sup end

    {:ok, daemon} = Daemon.start_link(Server, test_pid, server_supervisor: sup, forward_callers: true)
    {:ok, port} = Daemon.port(daemon)
    {:ok, client_pid} = Client.start_link(test_pid, port)

    assert_receive {:client_universe, ^test_pid}

    assert test_pid == GenServer.call(client_pid, :server_universe)
  end

  test "TCP/IP can be a wormhole between universes" do
    test_pid = self()

    spawn_link fn ->
      {:ok, daemon} = Daemon.start_link(Server, test_pid, forward_callers: true)
      {:ok, port} = Daemon.port(daemon)

      send(test_pid, {:port, port})

      receive do :never -> :die end
    end

    assert_receive {:port, port}

    {:ok, client_pid} = Client.start_link(test_pid, port)

    assert_receive {:client_universe, ^test_pid}

    refute test_pid == GenServer.call(client_pid, :server_universe)
  end
end
