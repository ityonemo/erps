defmodule ErpsTest do
  use ExUnit.Case, async: true

  @moduletag :erps

  alias Erps.Daemon

  defmodule Client do
    use Erps.Client

    @localhost {127, 0, 0, 1}

    def start_link(port) do
      Erps.Client.start_link(__MODULE__, :ok, server: @localhost, port: port)
    end

    def init(initial_state), do: {:ok, initial_state}

    def ping(srv), do: GenServer.call(srv, :ping)

    def cast(srv), do: GenServer.cast(srv, :cast)

  end

  defmodule Server do
    use Erps.Server

    def start_link(state, opts) do
      Erps.Server.start_link(__MODULE__, state, opts)
    end

    def init(test_pid) do
      send(test_pid, {:server, self()})
      {:ok, :waiting}
    end

    def state(srv), do: GenServer.call(srv, :state)

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
      {:ok, daemon} = Daemon.start_link(Server, self())
      {:ok, port} = Daemon.port(daemon)
      {:ok, client} = Client.start_link(port)
      assert :pong == Client.ping(client)
    end

    test "can accept a mutating cast" do
      {:ok, server} = Daemon.start_link(Server, self())
      {:ok, port} = Daemon.port(server)
      {:ok, client} = Client.start_link(port)

      assert_receive {:server, server}

      assert :waiting = Server.state(server)
      Client.cast(client)
      Process.sleep(20)
      assert :casted = Server.state(server)
    end
  end

  defmodule ClientVariableServer do

    use Erps.Client

    def start_link(daemon, name) do
      {:ok, port} = Daemon.port(daemon)
      Erps.Client.start_link(__MODULE__, :ok, server: name, port: port)
    end

    @impl true
    def init(state), do: {:ok, state}
  end

  describe "a client can be initialized" do
    test "with a string DNS name" do
      {:ok, daemon} = Daemon.start_link(Server, self())
      {:ok, client} = ClientVariableServer.start_link(daemon, "localhost")
      Process.sleep(20)
      assert :pong = GenServer.call(client, :ping)
    end
  end
end
