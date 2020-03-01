defmodule ErpsTest.Parameters.ClientTest do
  use ExUnit.Case, async: true

  alias Erps.Packet

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

  describe "when the client is versioned" do
    test "the cast packet is branded with its version", %{port: port} do
      {:ok, client} = ClientVersion.start_link(port)

      GenServer.cast(client, :foo)

      assert_receive {:tcp, _, data}
      {:ok, packet} = Packet.decode(data)

      assert "0.1.3" == "#{packet.version}"
    end

    test "the call packet is branded with its version", %{port: port} do
      {:ok, client} = ClientVersion.start_link(port)

      spawn_link(fn -> GenServer.call(client, :foo) end)

      assert_receive {:tcp, _, data}
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

      assert_receive {:tcp, _, data}
      {:ok, packet} = Packet.decode(data)

      assert "erpstest" == packet.identifier
    end

    test "the call packet is branded with its version", %{port: port} do
      {:ok, client} = ClientIdentifier.start_link(port)

      spawn_link(fn -> GenServer.call(client, :foo) end)

      assert_receive {:tcp, _, data}
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

  defmodule ClientSignatureLocal do
    @localhost {127, 0, 0, 1}

    use Erps.Client, sign_with: :signature

    @hmac_key fn -> Enum.random(?A..?Z) end |> Stream.repeatedly |> Enum.take(16) |> List.to_string
    @hmac_secret :crypto.strong_rand_bytes(32)

    def start_link(port) do
      Erps.Client.start_link(__MODULE__, port,
        server: @localhost,
        port: port)
    end

    def init(test_pid), do: {:ok, test_pid}

    def hmac_key, do: @hmac_key

    def signature(binary) do
      :crypto.mac(:hmac, :sha256, @hmac_secret, binary)
    end

    def verification(binary, @hmac_key, signature) do
      :crypto.mac(:hmac, :sha256, @hmac_secret, binary) == signature
    end
  end

  defmodule ClientSignatureLocalHmacFn do
    @localhost {127, 0, 0, 1}

    use Erps.Client, sign_with: :signature

    @hmac_key :hmac_key
    @hmac_secret :crypto.strong_rand_bytes(32)

    @hmac_fn_value fn -> Enum.random(?A..?Z) end |> Stream.repeatedly |> Enum.take(16) |> List.to_string

    def start_link(port) do
      Erps.Client.start_link(__MODULE__, port,
        server: @localhost,
        port: port)
    end

    def init(test_pid), do: {:ok, test_pid}

    def hmac_key, do: @hmac_fn_value

    def signature(binary) do
      :crypto.mac(:hmac, :sha256, @hmac_secret, binary)
    end

    def verification(binary, @hmac_fn_value, signature) do
      :crypto.mac(:hmac, :sha256, @hmac_secret, binary) == signature
    end
  end

  defmodule ClientSignatureLocalHmacRemoteFn do
    @localhost {127, 0, 0, 1}

    defmodule Remote do
      @hmac_fn_value fn -> Enum.random(?A..?Z) end |> Stream.repeatedly |> Enum.take(16) |> List.to_string

      def key, do: @hmac_fn_value
    end

    use Erps.Client, sign_with: :signature

    @hmac_key {Remote, :key}
    @hmac_secret :crypto.strong_rand_bytes(32)

    def start_link(port) do
      Erps.Client.start_link(__MODULE__, port,
        server: @localhost,
        port: port)
    end

    def init(test_pid), do: {:ok, test_pid}

    def hmac_key, do: Remote.key

    def signature(binary) do
      :crypto.mac(:hmac, :sha256, @hmac_secret, binary)
    end

    def verification(binary, _, signature) do
      :crypto.mac(:hmac, :sha256, @hmac_secret, binary) == signature
    end
  end

  defmodule ClientSignatureRemote do
    @localhost {127, 0, 0, 1}

    use Erps.Client, sign_with: {__MODULE__.Remote, :signature}

    defmodule Remote do
      @hmac_secret :crypto.strong_rand_bytes(32)

      def signature(binary, _) do
        :crypto.mac(:hmac, :sha256, @hmac_secret, binary)
      end
    end

    @hmac_key fn -> Enum.random(?A..?Z) end |> Stream.repeatedly |> Enum.take(16) |> List.to_string

    def start_link(port) do
      Erps.Client.start_link(__MODULE__, port,
        server: @localhost,
        port: port)
    end

    def init(test_pid), do: {:ok, test_pid}

    def hmac_key, do: @hmac_key

    def verification(binary, @hmac_key, signature) do
      Remote.signature(binary, @hmac_key) == signature
    end
  end

  describe "when the client is instrumented with signature" do
    test "it looks for local @hmac_key value", %{port: port} do
      {:ok, client1} = ClientSignatureLocal.start_link(port)
      GenServer.cast(client1, :foo)
      assert_receive {:tcp, _, signed_data}

      assert {:ok, _packet} =
        Packet.decode(signed_data,
          verification: &ClientSignatureLocal.verification/3)
    end

    test "it looks for local @hmac_key zero arity fn", %{port: port} do
      {:ok, client1} = ClientSignatureLocalHmacFn.start_link(port)
      GenServer.cast(client1, :foo)
      assert_receive {:tcp, _, signed_data}

      assert {:ok, _packet} =
        Packet.decode(signed_data,
          verification: &ClientSignatureLocalHmacFn.verification/3)
    end

    test "it looks for remote @hmac_key zero arity fn", %{port: port} do
      {:ok, client1} = ClientSignatureLocalHmacRemoteFn.start_link(port)
      GenServer.cast(client1, :foo)
      assert_receive {:tcp, _, signed_data}

      assert {:ok, _packet} =
        Packet.decode(signed_data,
          verification: &ClientSignatureLocalHmacRemoteFn.verification/3)
    end

    test "it can also use a remote signature function", %{port: port} do
      {:ok, client1} = ClientSignatureRemote.start_link(port)
      GenServer.cast(client1, :foo)
      assert_receive {:tcp, _, signed_data}

      assert {:ok, _packet} =
        Packet.decode(signed_data,
          verification: &ClientSignatureRemote.verification/3)
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
      assert {:ok, %{type: :keepalive}} = Packet.decode(receive do {:tcp, _, data} -> data end)
    end
  end
end
