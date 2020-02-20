defmodule ErpsTest.DualConnectionTest do

  use ExUnit.Case, async: true

  defmodule TestClient do
    use Erps.Client

    @localhost {127, 0, 0, 1}

    def start_link(port) do
      Erps.Client.start_link(__MODULE__, :ok, server: @localhost, port: port)
    end

    def init(state), do: {:ok, state}

    def ping(srv), do: Erps.Client.call(srv, :ping)
  end

  defmodule TestServer do
    use Erps.Server

    def start_link(state) do
      Erps.Server.start_link(__MODULE__, state, [])
    end

    def init(state), do: {:ok, state}

    def handle_call(:ping, _from, state) do
      {:reply, :pong, state}
    end
  end

  test "you can have two clients connected to the same server" do
    {:ok, server} = TestServer.start_link(:waiting)
    {:ok, port} = Erps.Server.port(server)
    {:ok, client1} = TestClient.start_link(port)
    {:ok, client2} = TestClient.start_link(port)
    assert :pong == TestClient.ping(client1)
    assert :pong == TestClient.ping(client2)
  end
end
