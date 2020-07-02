defmodule ErpsTest.DualConnectionTest do

  use ExUnit.Case, async: true

  alias Erps.Daemon

  defmodule Client do
    use Erps.Client

    @localhost IP.localhost()

    def start_link(port) do
      Erps.Client.start_link(__MODULE__, :ok, server: @localhost, port: port)
    end

    def init(state), do: {:ok, state}

    def ping(srv), do: GenServer.call(srv, :ping)
  end

  defmodule Server do
    use Erps.Server

    def start_link(state, opts) do
      Erps.Server.start_link(__MODULE__, state, opts)
    end

    def init(state), do: {:ok, state}

    def handle_call(:ping, _from, state) do
      {:reply, :pong, state}
    end
  end

  test "you can have two clients connected to the same server" do
    {:ok, daemon} = Daemon.start_link(Server, self())
    {:ok, port} = Daemon.port(daemon)

    {:ok, client1} = Client.start_link(port)
    {:ok, client2} = Client.start_link(port)

    assert :pong == Client.ping(client1)
    assert :pong == Client.ping(client2)
  end
end
