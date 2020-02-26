defmodule ErpsTest.Client.VersionTest do
  use ExUnit.Case, async: true

  alias Erps.Packet

  defmodule Client do
    use Erps.Client, version: "0.1.3"

    @localhost {127, 0, 0, 1}

    def start_link(port) do
      Erps.Client.start_link(__MODULE__, port,
        server: @localhost,
        port: port)
    end

    def init(test_pid), do: {:ok, test_pid}

  end

  setup do
    # ninjas in a mini-tcp-server.
    test_pid = self()

    spawn_link(fn ->
      {:ok, sock} = :gen_tcp.listen(0, [:binary, active: true])
      {:ok, port} = :inet.port(sock)
      send(test_pid, port)
      {:ok, asock} = :gen_tcp.accept(sock)
      # make test_pid the owner of the socket.
      :gen_tcp.controlling_process(asock, test_pid)

      # we don't need to do anything but stay alive for the lifetime of
      # the test.
      receive do :never -> :done end
    end)
    port = receive do port -> port end
    {:ok, port: port}
  end

  test "a cast from a client is branded with its version", %{port: port} do
    {:ok, client} = Client.start_link(port)

    Erps.Client.cast(client, :foo)

    assert_receive {:tcp, _, data}
    {:ok, packet} = Packet.decode(data)

    assert "0.1.3" == "#{packet.version}"
  end

  test "a call from a client is branded with its version", %{port: port} do
    {:ok, client} = Client.start_link(port)

    spawn_link(fn -> Erps.Client.call(client, :foo) end)

    assert_receive {:tcp, _, data}
    {:ok, packet} = Packet.decode(data)

    assert "0.1.3" == "#{packet.version}"
  end
end
