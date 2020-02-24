defmodule ErpsTest do
  use ExUnit.Case, async: true

  defmodule TestClient do
    use Erps.Client

    @localhost {127, 0, 0, 1}

    def start_link(port) do
      Erps.Client.start_link(__MODULE__, :ok, server: @localhost, port: port)
    end

    def init(val), do: {:ok, val}

    def ping(srv), do: Erps.Client.call(srv, :ping)

    def cast(srv), do: Erps.Client.cast(srv, :cast)

  end

  defmodule TestServer do
    use Erps.Server

    def start_link(state) do
      Erps.Server.start_link(__MODULE__, state, [])
    end

    def init(state), do: {:ok, state}

    def state(srv), do: Erps.Server.call(srv, :state)

    def handle_call(:ping, _from, state) do
      {:reply, :pong, state}
    end
    def handle_call(:state, _from, state) do
      {:reply, state, state}
    end

    def handle_cast(:cast, _state) do
      {:noreply, :casted}
    end
  end


  describe "An Erps server" do
    test "can accept a call" do
      {:ok, server} = TestServer.start_link(:waiting)
      {:ok, port} = Erps.Server.port(server)
      {:ok, client} = TestClient.start_link(port)
      assert :pong == TestClient.ping(client)
    end

    test "can accept a mutating cast" do
      {:ok, server} = TestServer.start_link(:waiting)
      {:ok, port} = Erps.Server.port(server)
      {:ok, client} = TestClient.start_link(port)
      TestClient.cast(client)
      Process.sleep(20)
      assert :casted = TestServer.state(server)
    end
  end
end
