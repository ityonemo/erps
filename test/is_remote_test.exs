defmodule ErpsTest.IsRemoteTest do
  # tests the `Erps.is_remote` guard
  use ExUnit.Case, async: true
  require Erps
  alias Erps.Daemon

  defmodule TestGenServer do
    use GenServer
    def start_link, do: GenServer.start_link(__MODULE__, nil)
    def init(nil), do: {:ok, nil}
    def handle_call(_, from, test_pid), do: {:reply, from, nil}
  end

  test "a normal GenServer's from resolves as false in is_remote/1" do
    {:ok, srv} = TestGenServer.start_link()
    refute Erps.is_remote(GenServer.call(srv, :foo))
  end

  defmodule TestClient do
    use Erps.Client

    @localhost IP.localhost()

    def start_link(port) do
      Erps.Client.start_link(__MODULE__, nil, server: @localhost, port: port)
    end

    def init(_), do: {:ok, nil}
  end

  defmodule TestServer do
    use Erps.Server

    def start_link(test_pid, opts) do
      Erps.Server.start_link(__MODULE__, test_pid, opts)
    end

    def init(test_pid), do: {:ok, test_pid}
    def handle_call(_, from, test_pid) do
      send(test_pid, {:from, from})
      {:reply, :ok, test_pid}
    end
  end

  test "an Erps.Server's from resolves as true in is_remote/1" do
    {:ok, daemon} = Daemon.start_link(TestServer, self())
    {:ok, port} = Daemon.port(daemon)
    {:ok, client} = TestClient.start_link(port)
    assert :ok = GenServer.call(client, :foo)
    assert Erps.is_remote(receive do {:from, from} -> from end)
  end

  defmodule TestGuarded do
    use Erps.Server

    def start_link(test_pid, opts) do
      Erps.Server.start_link(__MODULE__, test_pid, opts)
    end

    def init(test_pid) do
      send(test_pid, {:srv, self()})
      {:ok, test_pid}
    end

    def handle_call(_, from, test_pid) when Erps.is_remote(from) do
      send(test_pid, :remote)
      {:reply, :ok, test_pid}
    end
    def handle_call(_, from, test_pid) do
      send(test_pid, :local)
      {:reply, :ok, test_pid}
    end
  end

  test "is_remote/1 can be used in guards" do
    {:ok, daemon} = Daemon.start_link(TestGuarded, self())
    {:ok, port} = Daemon.port(daemon)

    {:ok, client} = TestClient.start_link(port)

    assert_receive {:srv, server}

    assert :ok = GenServer.call(client, :foo)
    assert_receive :remote
    refute_receive :local

    assert :ok = GenServer.call(server, :foo)
    assert_receive :local
    refute_receive :remote
  end

end
