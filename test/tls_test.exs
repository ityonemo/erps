defmodule ErpsTest.TlsTest do
  use ExUnit.Case, async: true

  @moduletag :tls

  alias Erps.Daemon

  defmodule Client do
    use Erps.Client

    import ErpsTest.TlsOpts

    @localhost IP.localhost()

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

    def start_link(test_pid, opts) do
      Erps.Server.start_link(__MODULE__, test_pid, opts)
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

  test "an erps system can make a connection via TLS" do
    import ErpsTest.TlsOpts

    options = [transport: Transport.Tls] ++ tls_opts("server")
    {:ok, daemon} = Daemon.start_link(Server, self(), options)
    {:ok, port} = Daemon.port(daemon)
    {:ok, client} = Client.start_link(port)
    assert :pong == Client.ping(client)
  end

  defmodule Server2 do
    use Erps.Server

    import ErpsTest.TlsOpts

    def start_link(test_pid, _opts) do
      options = [transport: Transport.Tls] ++ tls_opts("server")
      Erps.Server.start_link(__MODULE__, test_pid, options)
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

  test "tls options should be settable at the server layer" do
    {:ok, daemon} = Daemon.start_link(Server2, self())
    {:ok, port} = Daemon.port(daemon)
    {:ok, client} = Client.start_link(port)
    assert :pong == Client.ping(client)
  end

end
