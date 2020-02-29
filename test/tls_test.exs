defmodule ErpsTest.TlsTest do
  use ExUnit.Case, async: true

  defmodule Client do
    use Erps.Client

    @localhost {127, 0, 0, 1}

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
    def handle_call(call, from, test_pid) do\
      send(test_pid, call)
      {:reply, call, test_pid}
    end
  end

  def path(file) do
    Path.join(File.cwd!(), file) |> IO.inspect(label: "35")
    #Path.join(ErpsTest.TlsFiles.path(), file)
    #|> String.to_charlist
  end

  @tag :one
  test "happy path two way tls works" do
    {:ok, server} = Server.start_link(self(),
      strategy: Erps.TwoWayTLS,
      ssl_opts: [
        cacertfile: path("rootCA.pem"),
        certfile:   path("server.cert"),
        keyfile:    path("server.key")
      ])
    {:ok, port} = Server.port(server)
    {:ok, client} = Client.start_link(
      port: port,
      strategy: Erps.TwoWayTLS,
      ssl_opts: [
        cacertfile: path("rootCA.pem"),
        certfile:   path("client.cert"),
        keyfile:    path("client.key")
      ])

    assert :foo = GenServer.call(client, :foo)
    assert_receive :foo
  end

end
