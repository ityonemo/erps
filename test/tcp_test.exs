defmodule ErpsTest.TcpTest do
  use ExUnit.Case, async: true

  defmodule TestClient do
    use Erps.Client

    @localhost {127, 0, 0, 1}

    def start(port) do
      Erps.Client.start(__MODULE__, :ok, server: @localhost, port: port)
    end

    def start_link(port) do
      Erps.Client.start_link(__MODULE__, :ok, server: @localhost, port: port)
    end

    def init(start), do: {:ok, start}
  end

  defmodule TestServer do
    use Erps.Server

    def start_link(state) do
      Erps.Server.start_link(__MODULE__, state, [])
    end

    def init(state), do: {:ok, state}
  end

  test "server keeps track of one connection" do
    {:ok, server} = TestServer.start_link(:waiting)
    {:ok, port} = Erps.Server.port(server)
    {:ok, _client1} = TestClient.start_link(port)
    Process.sleep(20)
    assert [_port] = Erps.Server.connections(server)
  end

  test "server keeps track of multiple connections" do
    {:ok, server} = TestServer.start_link(:waiting)
    {:ok, port} = Erps.Server.port(server)
    {:ok, _client1} = TestClient.start_link(port)
    {:ok, _client2} = TestClient.start_link(port)
    Process.sleep(20)
    assert [_port1, _port2] = Erps.Server.connections(server)
  end

  test "server drops when connection is dropped" do
    {:ok, server} = TestServer.start_link(:waiting)
    {:ok, port} = Erps.Server.port(server)
    {:ok, client} = TestClient.start(port)
    Process.sleep(20)
    assert [sport] = Erps.Server.connections(server)
    Process.exit(client, :kill)
    Process.sleep(20)
    refute Port.info(sport) # presume the port has gone down.
    assert [] = Erps.Server.connections(server)
  end

  test "first connection is kept when the second connection is dropped" do
    {:ok, server} = TestServer.start_link(:waiting)
    {:ok, port} = Erps.Server.port(server)
    {:ok, _client1} = TestClient.start(port)
    Process.sleep(20)
    assert [sport] = Erps.Server.connections(server)
    {:ok, client2} = TestClient.start(port)
    Process.sleep(20)
    assert [_, _] = Erps.Server.connections(server)
    Process.exit(client2, :kill)
    Process.sleep(20)
    assert [^sport] = Erps.Server.connections(server)
  end
end
