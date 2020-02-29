defmodule ErpsTest.TlsTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  @moduletag :tls

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

  describe "for two way tls" do
    setup do
      {:ok, server} = Server.start_link(self(),
        strategy: Erps.TLS,
        ssl_opts: [
          cacertfile: path("rootCA.pem"),
          certfile:   path("server.cert"),
          keyfile:    path("server.key")
        ])
      {:ok, port} = Server.port(server)
      {:ok, client} = Client.start_link(
        port: port,
        strategy: Erps.TLS,
        ssl_opts: [
          cacertfile: path("rootCA.pem"),
          certfile:   path("client.cert"),
          keyfile:    path("client.key"),
          customize_hostname_check: Erps.TLS.single_ip_check(@localhost),
          reuse_sessions: false
        ])

      verify_good_client = fn ->
        assert :foo = GenServer.call(client, :foo)
        assert_receive :foo
      end

      :ssl.clear_pem_cache()

      {:ok, port: port, verify: verify_good_client}
    end

    test "the happy path works", %{verify: verify} do
      verify.()
    end

    @tag :one
    test "client can't connect over unencrypted channel", %{port: port, verify: verify} do
      {:ok, bad_client} = Client.start(port: port, strategy: Erps.TCP)
      Process.monitor(bad_client)
      assert Process.alive?(bad_client)
      spawn(fn -> GenServer.call(bad_client, :foo, 100) end)
      server_failure = capture_log(fn -> Process.sleep(100) end)
      # make sure that the bad client has been killed.
      assert_receive {:DOWN, _, :process, ^bad_client, :tcp_closed}
      assert server_failure =~ "Unexpected Message"
      assert server_failure =~ ":server:"
      #make sure good client still works
      verify.()
    end

    test "client can't connect with one way tls", %{port: port, verify: verify} do
      log = capture_log(fn ->
        assert {:error, _} = Client.start(port: port, strategy: Erps.OneWayTLS,
          ssl_opts: [cacertfile: path("rootCA.pem")])
        Process.sleep(100)
      end)
      [_, client, server] = String.split(log, "[info]")
      assert client =~ "Handshake Failure"
      assert client =~ ":client:"
      assert server =~ "Handshake Failure"
      assert server =~ ":server:"

      # make sure good client still works
      verify.()
    end

    test "client can't connect with the wrong root CA", %{port: port, verify: verify} do
      log = capture_log(fn ->
        assert {:error, _} = Client.start(
          port: port,
          strategy: Erps.TLS,
          ssl_opts: [
            cacertfile: path("wrong-rootCA.pem"),
            certfile:   path("wrong-root-client.cert"),
            keyfile:    path("wrong-root-client.key"),
            customize_hostname_check: Erps.TLS.single_ip_check(@localhost)
          ])
        Process.sleep(100)
      end)

      [_, client, server] = String.split(log, "[info]")
      assert client =~ "Unknown CA"
      assert client =~ ":client:"
      assert server =~ "Unknown CA"
      assert server =~ ":server:"

      # make sure good client is undisrupted
      verify.()
    end

    test "client can't connect with the wrong key", %{port: port, verify: verify} do
      log = capture_log(fn -> assert {:error, _} = Client.start(
        port: port,
        strategy: Erps.TLS,
        ssl_opts: [
          cacertfile: path("rootCA.pem"),
          certfile:   path("client.cert"),
          keyfile:    path("wrong-key.key"),
          customize_hostname_check: Erps.TLS.single_ip_check(@localhost),
          reuse_sessions: false
        ])
      end)

      [_, server, client] = String.split(log, "[info]")
      assert client =~ "Bad Certificate"
      assert client =~ ":client:"
      assert server =~ "Bad Certificate"
      assert server =~ ":server:"

      verify.()
    end

    test "client can't connect with the wrong host", %{port: port, verify: verify} do
      Client.start(
        port: port,
        strategy: Erps.TLS,
        ssl_opts: [
          cacertfile: path("rootCA.pem"),
          certfile:   path("wrong-host.cert"),
          keyfile:    path("wrong-host.key"),
          customize_hostname_check: Erps.TLS.single_ip_check(@localhost),
          reuse_sessions: false
        ])
      |> case do
        {:ok, bad_client} ->
          Process.monitor(bad_client)
          assert_receive {:DOWN, _, :process, ^bad_client, :ssl_closed}
        {:error, _any} ->
          :ok
      end

      verify.()
    end
  end
end
