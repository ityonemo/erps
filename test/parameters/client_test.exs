defmodule ErpsTest.Parameters.ClientTest do
  use ExUnit.Case, async: true

  alias Erps.Packet

  @moduletag :parameters

  defp accept_loop(test_pid, sock) do
    {:ok, asock} = :gen_tcp.accept(sock)
    # make test_pid the owner of the socket.
    :gen_tcp.controlling_process(asock, test_pid)
    accept_loop(test_pid, sock)
  end

  setup do
    # ninjas in a mini-tcp-server.
    test_pid = self()

    spawn_link(fn ->
      {:ok, sock} = :gen_tcp.listen(0, [:binary, active: true])
      {:ok, port} = :inet.port(sock)
      send(test_pid, port)
      accept_loop(test_pid, sock)
    end)
    port = receive do port -> port end
    {:ok, port: port}
  end

  defmodule ClientVersion do
    use Erps.Client, version: "0.1.3"

    @localhost {127, 0, 0, 1}

    def start_link(port) do
      Erps.Client.start_link(__MODULE__, port,
        server: @localhost,
        port: port)
    end

    def init(test_pid), do: {:ok, test_pid}
  end

  defmacrop assert_tcp_packet do
    quote do
      assert_receive {:tcp, _, <<?e, ?r, ?p, ?s, _size::32>> <> data}
      data
    end
  end

  describe "when the client is versioned" do
    test "the cast packet is branded with its version", %{port: port} do
      {:ok, client} = ClientVersion.start_link(port)

      GenServer.cast(client, :foo)

      data = assert_tcp_packet()
      {:ok, packet} = Packet.decode(data)

      assert "0.1.3" == "#{packet.version}"
    end

    test "the call packet is branded with its version", %{port: port} do
      {:ok, client} = ClientVersion.start_link(port)

      spawn_link(fn -> GenServer.call(client, :foo) end)

      data = assert_tcp_packet()
      {:ok, packet} = Packet.decode(data)

      assert "0.1.3" == "#{packet.version}"
    end
  end

  defmodule ClientIdentifier do
    use Erps.Client, identifier: "erpstest"

    @localhost {127, 0, 0, 1}

    def start_link(port) do
      Erps.Client.start_link(__MODULE__, port,
        server: @localhost,
        port: port)
    end

    def init(test_pid), do: {:ok, test_pid}
  end

  describe "when the client is instrumented with an identifier" do
    test "the cast packet is branded with its identifier", %{port: port} do
      {:ok, client} = ClientIdentifier.start_link(port)

      GenServer.cast(client, :foo)

      data = assert_tcp_packet()
      {:ok, packet} = Packet.decode(data)

      assert "erpstest" == packet.identifier
    end

    test "the call packet is branded with its version", %{port: port} do
      {:ok, client} = ClientIdentifier.start_link(port)

      spawn_link(fn -> GenServer.call(client, :foo) end)

      data = assert_tcp_packet()
      {:ok, packet} = Packet.decode(data)

      assert "erpstest" == packet.identifier
    end
  end

  defmodule ClientCompressionLow do
    use Erps.Client, compressed: 1

    @localhost {127, 0, 0, 1}

    def start_link(port) do
      Erps.Client.start_link(__MODULE__, port,
        server: @localhost,
        port: port)
    end

    def init(test_pid), do: {:ok, test_pid}
  end

  defmodule ClientCompressionHigh do
    use Erps.Client, compressed: 9

    @localhost {127, 0, 0, 1}

    def start_link(port) do
      Erps.Client.start_link(__MODULE__, port,
        server: @localhost,
        port: port)
    end

    def init(test_pid), do: {:ok, test_pid}
  end

  defmodule ClientCompressionDefault do
    use Erps.Client, compressed: true

    @localhost {127, 0, 0, 1}

    def start_link(port) do
      Erps.Client.start_link(__MODULE__, port,
        server: @localhost,
        port: port)
    end

    def init(test_pid), do: {:ok, test_pid}
  end

  @compressible_payload {%{payload: "payload", loadpay: "fooled",
  payday: "failed", daycare: "duped"}, :crypto.strong_rand_bytes(24),
  ["payload", "foolish"]}

  describe "when the client is instrumented with compression" do
    test "the cast packet is compressed", %{port: port} do
      {:ok, client1} = ClientVersion.start_link(port)
      GenServer.cast(client1, @compressible_payload)
      assert_receive {:tcp, _, data_uncompressed}

      {:ok, client2} = ClientCompressionDefault.start_link(port)
      GenServer.cast(client2, @compressible_payload)
      assert_receive {:tcp, _, data_compressed}

      assert :erlang.size(data_uncompressed) > :erlang.size(data_compressed)
    end

    test "the cast packet can have varying levels of compression", %{port: port} do
      {:ok, client1} = ClientCompressionLow.start_link(port)
      GenServer.cast(client1, @compressible_payload)
      assert_receive {:tcp, _, compressed_low}

      {:ok, client2} = ClientCompressionHigh.start_link(port)
      GenServer.cast(client2, @compressible_payload)
      assert_receive {:tcp, _, compressed_high}

      assert :erlang.size(compressed_low) > :erlang.size(compressed_high)
    end
  end

  defmodule ClientKeepalive do

    use Erps.Client

    @localhost {127, 0, 0, 1}

    def start_link(port) do
      Erps.Client.start_link(__MODULE__, port,
        server: @localhost,
        port: port,
        keepalive: 100)
    end

    def init(test_pid), do: {:ok, test_pid}
  end

  describe "when the client is instrumented with a keepalive" do
    test "the server gets a keepalive", %{port: port} do
      {:ok, _} = ClientKeepalive.start_link(port)
      Process.sleep(200)
      assert {:ok, %{type: :keepalive}} = Packet.decode(
        receive do
          {:tcp, _, <<?e, ?r, ?p, ?s, _size::32>> <> data} -> data
        end)
    end
  end
end
