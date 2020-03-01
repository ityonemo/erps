defmodule ErpsTest.OtpTest do
  use ExUnit.Case, async: true

  @moduletag :otp

  defmodule Client do
    use Erps.Client

    @localhost {127, 0, 0, 1}

    def start(test_pid, opts) do
      Erps.Client.start(__MODULE__, test_pid, [server: @localhost] ++ opts)
    end

    def start_link(test_pid, opts) do
      Erps.Client.start_link(__MODULE__, test_pid, [server: @localhost] ++ opts)
    end

    def handle_push(:die, state), do: {:stop, :die, state}
    def handle_push(:ping, test_pid) do
      send(test_pid, :ping)
      {:noreply, test_pid}
    end

    def init(start), do: {:ok, start}
  end

  defmodule Server do
    use Erps.Server

    def start(state) do
      Erps.Server.start(__MODULE__, state, [])
    end

    def start_link(state, opts \\ []) do
      Erps.Server.start_link(__MODULE__, state, opts)
    end

    def init(state), do: {:ok, state}
  end

  describe "when you kill the client" do
    test "the server is okay" do
      {:ok, server} = Server.start_link(:ok)
      {:ok, port} = Erps.Server.port(server)
      {:ok, client} = Client.start(self(), port: port)

      Process.sleep(20)
      Process.exit(client, :kill)
      Process.sleep(50)

      assert Process.alive?(server)
    end
  end

  describe "when you kill the server" do
    test "client will get killed" do
      {:ok, server} = Server.start(:ok)
      {:ok, port} = Erps.Server.port(server)
      {:ok, client} = Client.start(self(), port: port)
      # watch the client
      Process.monitor(client)

      Process.sleep(20)
      Process.exit(server, :kill)

      assert_receive {:DOWN, _, _, ^client, :tcp_closed}, 500
    end
  end

  describe "a supervised server/client pair" do
    test "has the client reconnect if it dies" do
      port = Enum.random(10_000..30_000)
      server_spec = %{id: Server, start: {Server, :start_link, [:ok, [port: port, name: :server1]]}}
      Supervisor.start_link([server_spec], strategy: :one_for_one)
      Process.sleep(20)
      client_spec = %{id: Client, start: {Client, :start_link, [self(), [port: port]]}}
      {:ok, client_sup} = Supervisor.start_link([client_spec], strategy: :one_for_one)
      Process.sleep(20)

      # retrieve the client PID
      [{_, client, _, _}] = Supervisor.which_children(client_sup)
      Process.monitor(client)

      # make sure we can perform a connection.
      Server.push(:server1, :ping)
      assert_receive :ping

      # now kill the client.
      Process.exit(client, :kill)

      assert_receive {:DOWN, _, _, ^client, :killed}, 500

      # let it reconnect
      Process.sleep(20)

      # but we can still use the connection
      Server.push(:server1, :ping)
      assert_receive :ping
    end

    @tag :one
    test "has the connection reestablish if both sides die" do
      port = Enum.random(10_000..30_000)
      test_pid = self()

      # peform supervision out of band so that we don't trap a stray "killed" signal.
      sups = spawn(fn ->
        server_spec = %{id: Server, start: {Server, :start_link, [:ok, [port: port, name: :server2]]}}
        {:ok, server_sup} = Supervisor.start_link([server_spec], strategy: :one_for_one)
        client_spec = %{id: Client, start: {Client, :start_link, [test_pid, [port: port]]}}
        {:ok, client_sup} = Supervisor.start_link([client_spec], strategy: :one_for_one)
        Process.sleep(20)
        send(test_pid, {server_sup, client_sup})
        receive do :done -> :done end
      end)

      {server_sup, client_sup} = receive do any -> any end

      # retrieve the server and client PIDs
      [{_, server, _, _}] = Supervisor.which_children(server_sup)
      [{_, client, _, _}] = Supervisor.which_children(client_sup)
      Process.monitor(server)
      Process.monitor(client)

      # make sure we can perform a connection.
      Server.push(:server2, :ping)
      assert_receive :ping

      # now kill the server.
      Process.exit(server, :kill)

      # check that our server has died.
      assert_receive {:DOWN, _, _, ^server, :killed}, 500
      assert_receive {:DOWN, _, _, ^client, :tcp_closed}, 200

      Process.sleep(200)

      # but we can still use the connection
      Server.push(:server2, :ping)
      assert_receive :ping

      # clean up the supervisors
      send(sups, :done)
    end
  end
end
