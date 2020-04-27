defmodule ErpsTest.TlsTest.TwoWayTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  alias Erps.Transport.Tls

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

  # we have to use a custom match function to verify server-side that
  # the client is using a certificate that we are ready to accept.
  @dns_name {2, 5, 29, 17}
  def server_match_fun(socket, raw_cert) do
    {:ok, cert} = X509.Certificate.from_der(raw_cert)

    # retrieve the DNSname field and attempt to match it.
    {:Extension, _, _, [dNSName: dnsname]} =
      X509.Certificate.extension(cert, @dns_name)

    {:ok, {ip_addr, _}} = :inet.peername(socket)

    if dnsname == :inet.ntoa(ip_addr) do
      :ok
    else
      {:error, "validation fail"}
    end
  end

  # because we're not using true FQDNs to sign our test-mode certs,
  # we have to use this function to customize our hostname check.
  def client_match_fun({:ip, ip}, {:dNSName, dns}) do
    :inet.ntoa(ip) == dns
  end
  def client_match_fun(_, _), do: false

  describe "for two way tls" do
    setup do
      {:ok, server} = Server.start_link(self(),
        transport: Tls,
        tls_opts: [
          cacertfile: path("rootCA.pem"),
          certfile:   path("server.cert"),
          keyfile:    path("server.key"),
          client_verify_fun: &server_match_fun/2
        ])

      {:ok, port} = Server.port(server)

      {:ok, client} = Client.start_link(
        port: port,
        transport: Tls,
        tls_opts: [
          cacertfile: path("rootCA.pem"),
          certfile:   path("client.cert"),
          keyfile:    path("client.key"),
          customize_hostname_check: [match_fun: &client_match_fun/2],
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

    test "client can't connect over unencrypted channel", %{port: port, verify: verify} do
      {:ok, bad_client} = Client.start(port: port, transport: Erps.Transport.Tcp)
      Process.monitor(bad_client)
      assert Process.alive?(bad_client)
      spawn(fn -> GenServer.call(bad_client, :foo, 100) end)
      server_failure = capture_log(fn -> Process.sleep(100) end)
      # make sure that the bad client has been killed.
      assert_receive {:DOWN, _, :process, ^bad_client, _}
      assert server_failure =~ "Unexpected Message"
      assert server_failure =~ ":server:"
      #make sure good client still works
      verify.()
    end

    test "the client must have tls options activated", %{port: port} do
      assert {:error, _} = Client.start(port: port, transport: Tls)
    end

    test "client can't connect with the wrong root CA", %{port: port, verify: verify} do
      log = capture_log(fn ->
        assert {:error, _} = Client.start(
          port: port,
          transport: Tls,
          tls_opts: [
            cacertfile: path("wrong-rootCA.pem"),
            certfile:   path("wrong-root.cert"),
            keyfile:    path("wrong-root.key"),
            customize_hostname_check: [match_fun: &client_match_fun/2],
          ])
        Process.sleep(100)
      end)

      assert log =~ "Unknown CA"

      # make sure good client is undisrupted
      verify.()
    end

    test "client can't connect with valid cert rooted to wrong root CA", %{port: port, verify: verify} do

      log = capture_log fn ->
        assert {:error, _} = Client.start(
          port: port,
          transport: Tls,
          tls_opts: [
            cacertfile: path("rootCA.pem"),
            certfile:   path("wrong-root.cert"),
            keyfile:    path("wrong-root.key"),
            customize_hostname_check: [match_fun: &client_match_fun/2],
          ])

        Process.sleep(100)
      end

      assert log =~ "Unknown CA"

      # make sure good client is undisrupted
      verify.()
    end

    test "client can't connect with the wrong key", %{port: port, verify: verify} do
      log = capture_log(fn -> assert {:error, _} = Client.start(
        port: port,
        transport: Tls,
        tls_opts: [
          cacertfile: path("rootCA.pem"),
          certfile:   path("client.cert"),
          keyfile:    path("wrong-key.key"),
          customize_hostname_check: [match_fun: &client_match_fun/2],
          reuse_sessions: false
        ])
      end)

      assert log =~ "Bad Certificate"

      verify.()
    end

    test "client can't connect with the wrong host", %{port: port, verify: verify} do
      Client.start(
        port: port,
        transport: Tls,
        tls_opts: [
          cacertfile: path("rootCA.pem"),
          certfile:   path("wrong-host.cert"),
          keyfile:    path("wrong-host.key"),
          customize_hostname_check: [match_fun: &client_match_fun/2],
          reuse_sessions: false
        ])
      |> case do
        {:ok, bad_client} ->
          Process.monitor(bad_client)
          assert_receive {:DOWN, _, :process, ^bad_client, :closed}, 500
        {:error, _any} ->
          :ok
      end

      verify.()
    end
  end

  describe "for two way tls with the server certificates" do
    test "the server must have tls options provided" do
      assert {:error, _} = Server.start(self(), transport: Tls)
    end

    test "the server must have a valid cacert file" do
      assert {:error, _} = Server.start(self(),
        transport: Tls,
        tls_opts: [
          certfile:   path("server.cert"),
          keyfile:    path("server.key")
        ])

      assert {:error, _} = Server.start(self(),
        transport: Tls,
        tls_opts: [
          cacertfile: path("not_a_file"),
          certfile:   path("server.cert"),
          keyfile:    path("server.key")
        ])
    end

    test "the server must have a valid cert file" do
      assert {:error, _} = Server.start(self(),
        transport: Tls,
        tls_opts: [
          cacertfile: path("rootCA.pem"),
          keyfile:    path("server.key")
        ])

      assert {:error, _} = Server.start(self(),
        transport: Tls,
        tls_opts: [
          cacertfile: path("rootCA.pem"),
          certfile:   path("not_a_file"),
          keyfile:    path("server.key")
        ])
    end

    test "the server must have a valid key file" do
      assert {:error, _} = Server.start(self(),
        transport: Tls,
        tls_opts: [
          cacertfile: path("rootCA.pem"),
          certfile:   path("server.cert")
        ])

      assert {:error, _} = Server.start(self(),
        transport: Tls,
        tls_opts: [
          cacertfile: path("rootCA.pem"),
          certfile:   path("server.cert"),
          keyfile:    path("not_a_file")
        ])
    end

    # note that fully disjoint CAs is already tested in the previous section.
    test "client rejects if the server cert is rooted to the wrong root CA" do
      {:ok, server} = Server.start_link(self(),
        transport: Tls,
        tls_opts: [
          cacertfile: path("rootCA.pem"),
          certfile:   path("wrong-root.cert"),
          keyfile:    path("wrong-root.key")
        ])
      {:ok, port} = Server.port(server)

      log = capture_log(fn ->
        assert {:error, _} = Client.start(
          port: port,
          transport: Tls,
          tls_opts: [
            cacertfile: path("rootCA.pem"),
            certfile:   path("client.cert"),
            keyfile:    path("client.key"),
            customize_hostname_check: [match_fun: &client_match_fun/2],
            reuse_sessions: false])
        Process.sleep(100)
      end)

      assert log =~ "Unknown CA"
    end

    test "client rejects if the server has the wrong key" do
      {:ok, server} = Server.start_link(self(),
        transport: Tls,
        tls_opts: [
          cacertfile: path("rootCA.pem"),
          certfile:   path("server.cert"),
          keyfile:    path("wrong-key.key")
        ])
      {:ok, port} = Server.port(server)

      assert {:error, _} = Client.start(
        port: port,
        transport: Tls,
        tls_opts: [
          cacertfile: path("rootCA.pem"),
          certfile:   path("client.cert"),
          keyfile:    path("client.key"),
          customize_hostname_check: [match_fun: &client_match_fun/2],
          reuse_sessions: false])
    end
  end

end
