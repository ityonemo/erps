defmodule ErpsTest.OtpTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  alias Erps.Daemon

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

    def handle_push(any, test_pid) do
      send(test_pid, any)
      {:noreply, test_pid}
    end

    def init(start), do: {:ok, start}
  end

  defmodule Server do
    use Erps.Server

    def start(test_pid) do
      Erps.Server.start(__MODULE__, test_pid, [])
    end

    def start_link(test_pid, opts \\ []) do
      Erps.Server.start_link(__MODULE__, test_pid, opts)
    end

    def init(test_pid) do
      send(test_pid, {:server, self()})
      {:ok, test_pid}
    end
  end

  describe "when you kill the client" do
    test "the server dies" do
      {:ok, sup} = DynamicSupervisor.start_link(strategy: :one_for_one)
      {:ok, daemon} = Daemon.start_link(Server, self(), server_supervisor: sup)
      {:ok, port} = Daemon.port(daemon)
      {:ok, client} = Client.start(self(), port: port)

      server = receive do {:server, server} -> server end
      # watch the client and server
      Process.monitor(client)
      Process.monitor(server)

      Process.sleep(20)

      log = capture_log(fn ->
        Process.exit(client, :kill)
        assert_receive {:DOWN, _, _, ^client, :killed}, 500
        assert_receive {:DOWN, _, _, ^server, :disconnected}, 500
      end)

      assert log =~ "error"
      assert log =~ "disconnected"
    end
  end

  describe "when you kill the server" do
    test "client will get killed" do
      {:ok, sup} = DynamicSupervisor.start_link(strategy: :one_for_one)
      {:ok, daemon} = Daemon.start_link(Server, self(), server_supervisor: sup)
      {:ok, port} = Daemon.port(daemon)
      {:ok, client} = Client.start(self(), port: port)

      server = receive do {:server, server} -> server end
      # watch the client and server
      Process.monitor(client)
      Process.monitor(server)

      # kill the server
      Process.sleep(20)
      log = capture_log(fn ->
        Process.exit(server, :kill)
        assert_receive {:DOWN, _, _, ^server, :killed}, 500
        assert_receive {:DOWN, _, _, ^client, :disconnected}, 500
      end)

      assert log =~ "error"
      assert log =~ "disconnected"

    end
  end

  describe "a supervised server/client pair" do
    test "has the client reconnect if it dies" do
      {:ok, server_sup} = DynamicSupervisor.start_link(strategy: :one_for_one)
      {:ok, daemon} = Daemon.start_link(Server, self(), server_supervisor: server_sup)
      {:ok, port} = Daemon.port(daemon)

      {:ok, client_sup} = DynamicSupervisor.start_link(strategy: :one_for_one)
      {:ok, client} = DynamicSupervisor.start_child(client_sup, {Client, {self(), port: port}})

      assert_receive {:server, server}
      # watch the client and server
      Process.monitor(client)
      Process.monitor(server)

      # wait for a bit...
      Process.sleep(20)
      log = capture_log(fn ->
        Process.exit(client, :kill)

        # wait for it...
        assert_receive {:DOWN, _, _, ^client, :killed}, 500
        assert_receive {:DOWN, _, _, ^server, :disconnected}, 500
      end)

      assert log =~ "error"
      assert log =~ "disconnected"

      # the server will be rezzed and we will be able to use it to
      # send a message via the new client.
      assert_receive {:server, new_server}
      Erps.Server.push(new_server, :foo)
      assert_receive(:foo)
    end

    test "has the server reconnect if it dies" do
      {:ok, server_sup} = DynamicSupervisor.start_link(strategy: :one_for_one)
      {:ok, daemon} = Daemon.start_link(Server, self(), server_supervisor: server_sup)
      {:ok, port} = Daemon.port(daemon)

      {:ok, client_sup} = DynamicSupervisor.start_link(strategy: :one_for_one)
      {:ok, client} = DynamicSupervisor.start_child(client_sup, {Client, {self(), port: port}})

      assert_receive {:server, server}
      # watch the client and server
      Process.monitor(client)
      Process.monitor(server)

      # wait for a bit...
      Process.sleep(20)
      log = capture_log(fn ->
        Process.exit(server, :kill)

        # wait for it...
        assert_receive {:DOWN, _, _, ^server, :killed}, 500
        assert_receive {:DOWN, _, _, ^client, :disconnected}, 500
      end)

      assert log =~ "error"
      assert log =~ "disconnected"

      # the server will be rezzed and we will be able to use it to
      # send a message via the new client.
      assert_receive {:server, new_server}
      # wait for connection renegotiation
      Process.sleep(20)
      Erps.Server.push(new_server, :foo)
      assert_receive(:foo)
    end
  end

  describe "custom supervisor module strategy works" do
    test "client will get killed" do
      {:ok, sup} = DynamicSupervisor.start_link(strategy: :one_for_one)
      {:ok, daemon} = Daemon.start_link(Server, self(),
        server_supervisor: {DynamicSupervisor, sup})
      {:ok, port} = Daemon.port(daemon)
      {:ok, _client} = Client.start_link(self(), port: port)

      assert_receive {:server, server}
      Process.sleep(20)
      Erps.Server.push(server, :foo)
      assert_receive(:foo)
    end
  end

  @tag :one
  test "supervising the daemon" do
    {:ok, sup} = DynamicSupervisor.start_link(strategy: :one_for_one)
    port = Enum.random(10000..20000)
    children = [{Daemon, {Server, self(), port: port, server_supervisor: sup}}]
    Supervisor.start_link(children, strategy: :one_for_one)

    {:ok, _client} = Client.start_link(self(), port: port)

    assert_receive {:server, server}
    Process.sleep(20)
    Erps.Server.push(server, :foo)
    assert_receive(:foo)
  end

end
