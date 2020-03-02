defmodule ErpsTest.TlsTest.OneWayTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  @moduletag :tls
  @logsleep 200

  alias Erps.Strategy.{OneWayTls, Tcp, Tls}

  defmodule Client do
    use Erps.Client

    @localhost {127, 0, 0, 1}

    def start(opts) do
      Erps.Client.start(__MODULE__, :ok, [server: @localhost] ++ opts)
    end

    def start_link(opts) do
      Erps.Client.start_link(__MODULE__, :ok, [server: @localhost] ++ opts)
    end

    @impl true
    def init(start), do: {:ok, start}
  end

  defmodule Server do
    use Erps.Server

    def start(test_pid, opts) do
      Erps.Server.start(__MODULE__, test_pid, opts)
    end
    def start_link(test_pid, opts) do
      Erps.Server.start_link(__MODULE__, test_pid, opts)
    end

    @impl true
    def init(test_pid), do: {:ok, test_pid}

    @impl true
    def handle_call(call, _from, test_pid) do
      send(test_pid, call)
      {:reply, call, test_pid}
    end
  end

  def path(file) do
    Path.join(ErpsTest.TlsFiles.path(), file)
  end

  @localhost {127, 0, 0, 1}

  def make_server(fun \\ :start_link, opts) do
    with {:ok, server} <- apply(Server, fun, [self(), [strategy: OneWayTls, tls_opts: opts]]),
         {:ok, port} <- Server.port(server) do
      port
    end
  end

  def make_client(fun \\ :start_link, port) do
    apply(Client, fun, [[
      port: port,
      strategy: Erps.Strategy.OneWayTls,
      tls_opts: [
        cacertfile: path("rootCA.pem"),
        customize_hostname_check: Tls.single_ip_check(@localhost),
        reuse_sessions: false
      ]]])
  end

  describe "for one way tls" do
    test "the happy path works" do
      port = make_server(
        cacertfile: path("rootCA.pem"),
        certfile:   path("server.cert"),
        keyfile:    path("server.key"))

      {:ok, client} = make_client(port)
      assert :foo = GenServer.call(client, :foo)
      assert_receive :foo
    end

    ###########################################################################
    ## SERVER MISCONFIGURATION

    test "server requires cacertfile" do
      {:error, _} = make_server(:start,
        certfile:   path("server.cert"),
        keyfile:    path("server.key"))

      {:error, _} = make_server(:start,
        cacertfile: path("not_a_file"),
        certfile:   path("server.cert"),
        keyfile:    path("server.key"))
    end

    test "server requires certfile" do
      {:error, _} = make_server(:start,
        cacertfile: path("rootCA.pem"),
        keyfile:    path("server.key"))

      {:error, _} = make_server(:start,
        cacertfile: path("rootCA.pem"),
        certfile:   path("not_a_file"),
        keyfile:    path("server.key"))
    end

    test "server requires keyfile" do
      {:error, _} = make_server(:start,
        cacertfile: path("rootCA.pem"),
        certfile:   path("server.cert"))

      {:error, _} = make_server(:start,
        cacertfile: path("rootCA.pem"),
        certfile:   path("server.cert"),
        keyfile:    path("not_a_file"))
    end

    ###########################################################################
    ## CLIENT MISCONFIGURATION

    test "client can't connect over unencrypted channel" do
      port = make_server(
        cacertfile: path("rootCA.pem"),
        certfile:   path("server.cert"),
        keyfile:    path("server.key"))
      {:ok, client} = make_client(port)

      {:ok, bad_client} = Client.start(port: port, strategy: Tcp)
      Process.monitor(bad_client)
      assert Process.alive?(bad_client)
      spawn(fn -> GenServer.call(bad_client, :foo, 100) end)
      server_failure = capture_log(fn -> Process.sleep(@logsleep) end)
      # make sure that the bad client has been killed.
      assert_receive {:DOWN, _, :process, ^bad_client, :tcp_closed}
      assert server_failure =~ "Unexpected Message"
      assert server_failure =~ ":server:"
      #make sure good client still works
      assert :foo = GenServer.call(client, :foo)
      assert_receive :foo
    end

    test "the client must have tls options activated" do
      port = make_server(
        cacertfile: path("rootCA.pem"),
        certfile:   path("server.cert"),
        keyfile:    path("server.key"))
      assert {:error, _} = Client.start(port: port, strategy: Tls)
    end

    ###########################################################################
    ## SERVER IDENTITY SPOOFING

    test "client rejects if the server chain is for the wrong root CA" do
      port = make_server(
        cacertfile: path("wrong-rootCA.pem"),
        certfile:   path("wrong-root.cert"),
        keyfile:    path("wrong-root.key"))

      log = capture_log(fn ->
        assert {:error, client} = make_client(:start, port)
        Process.sleep(@logsleep)
      end)

      assert log =~ "Unknown CA"
    end

    test "client rejects if the server chain is rooted to the wrong CA" do
      port = make_server(
        cacertfile: path("rootCA.pem"),
        certfile:   path("wrong-root.cert"),
        keyfile:    path("wrong-root.key"))

      log = capture_log(fn ->
        assert {:error, client} = make_client(:start, port)
        Process.sleep(@logsleep)
      end)

      assert log =~ "Unknown CA"
    end

    test "client rejects if the server chain has the wrong key" do
      port = make_server(
        cacertfile: path("rootCA.pem"),
        certfile:   path("server.cert"),
        keyfile:    path("wrong-key.key"))

      log = capture_log(fn ->
        assert {:error, client} = make_client(:start, port)
        Process.sleep(@logsleep)
      end)

      assert log =~ "Decrypt Error"
    end
  end
end
