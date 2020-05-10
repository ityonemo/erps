defmodule ErpsTest.TlsTest do
  use ExUnit.Case, async: true

  @moduletag :erps

  alias Erps.Daemon

  defmodule Client do
    use Erps.Client

    import ErpsTest.TlsOpts

    @localhost {127, 0, 0, 1}

    def start_link(port) do
      Erps.Client.start_link(__MODULE__, :ok,
        [server: @localhost,
        port: port,
        transport: Transport.Tls]
        ++ tls_opts("client"))
    end

    def init(initial_state), do: {:ok, initial_state}

    def ping(srv), do: GenServer.call(srv, :ping)

    def cast(srv), do: GenServer.cast(srv, :cast)

  end

  defmodule Server do
    use Erps.Server

    def start_link(test_pid) do
      Erps.Server.start_link(__MODULE__, test_pid)
    end

    def init(test_pid) do
      send(test_pid, {:server, self()})
      {:ok, :waiting}
    end

    def state(srv), do: GenServer.call(srv, :state)

    def handle_call(:ping, _from, state) do
      {:reply, :pong, state}
    end

    def handle_cast(:cast, _state) do
      {:noreply, :casted}
    end
  end

  @tag :one
  test "an erps system can make a connection via TLS" do
    import ErpsTest.TlsOpts

    options = [transport: Transport.Tls] ++ tls_opts("server")
    {:ok, daemon} = Daemon.start_link(Server, self(), options)
    {:ok, port} = Daemon.port(daemon)
    {:ok, client} = Client.start_link(port)
    assert :pong == Client.ping(client)
  end
end
