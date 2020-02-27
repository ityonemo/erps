defmodule ErpsTest.Parameters.ServerTest do
  use ExUnit.Case, async: true

  defmodule ServerVersion do
    use Erps.Server, versions: "~> 0.1.3"

    def start_link(test_pid) do
      Erps.Server.start_link(__MODULE__, test_pid)
    end

    def init(test_pid), do: {:ok, test_pid}

    def handle_call(:ping, _from, test_pid) do
      send(test_pid, {:reply, :pong, test_pid})
    end
  end

  alias Erps.Packet

  @localhost {127, 0, 0, 1}
  describe "when the server is versioned" do
    test "a properly versioned packet gets accepted" do
      {:ok, server} = ServerVersion.start_link(self())
      {:ok, port} = ServerVersion.port(server)

      {:ok, sock} = :gen_tcp.connect(@localhost, port, [:binary, active: true])

      packet = Packet.encode(
        %Packet{type: :call,
          version: %Version{major: 0, minor: 1, patch: 3, pre: []},
          payload: {:from, :ping}})

      :gen_tcp.send(sock, packet)

      assert_receive {:reply, :pong, _ }

      assert {:ok, %Packet{type: :reply, payload: {:pong, :from}}} =
        Packet.decode(receive do {:tcp, _, packet} -> packet end)
    end

    test "an unversioned packet gets rejected" do
      {:ok, server} = ServerVersion.start_link(self())
      {:ok, port} = ServerVersion.port(server)

      {:ok, sock} = :gen_tcp.connect(@localhost, port, [:binary, active: true])

      packet = Packet.encode(
        %Packet{type: :call,
          payload: {:from, :ping}})

      :gen_tcp.send(sock, packet)

      refute_receive {:reply, :pong, _ }

      assert {:ok, %Packet{type: :error}} =
        Packet.decode(receive do {:tcp, _, packet} -> packet end)
    end

    test "an old version packet gets rejected" do
      {:ok, server} = ServerVersion.start_link(self())
      {:ok, port} = ServerVersion.port(server)

      {:ok, sock} = :gen_tcp.connect(@localhost, port, [:binary, active: true])

      packet = Packet.encode(
        %Packet{type: :call,
          version: %Version{major: 0, minor: 0, patch: 3, pre: []},
          payload: {:from, :ping}})

      :gen_tcp.send(sock, packet)

      refute_receive {:reply, :pong, _ }

      assert {:ok, %Packet{type: :error}} =
        Packet.decode(receive do {:tcp, _, packet} -> packet end)
    end

    test "an incompatibly versioned packet gets rejected" do
      {:ok, server} = ServerVersion.start_link(self())
      {:ok, port} = ServerVersion.port(server)

      {:ok, sock} = :gen_tcp.connect(@localhost, port, [:binary, active: true])

      packet = Packet.encode(
        %Packet{type: :call,
          version: %Version{major: 2, minor: 1, patch: 3, pre: []},
          payload: {:from, :ping}})

      :gen_tcp.send(sock, packet)

      refute_receive {:reply, :pong, _ }

      assert {:ok, %Packet{type: :error}} =
        Packet.decode(receive do {:tcp, _, packet} -> packet end)
    end
  end

  defmodule ServerIdentifier do
    use Erps.Server, identifier: "foobar"

    def start_link(test_pid) do
      Erps.Server.start_link(__MODULE__, test_pid)
    end

    def init(test_pid), do: {:ok, test_pid}

    def handle_call(:ping, _from, test_pid) do
      send(test_pid, {:reply, :pong, test_pid})
    end
  end

  describe "when the server has an identifier" do
    test "a properly identified packet gets accepted" do
      {:ok, server} = ServerIdentifier.start_link(self())
      {:ok, port} = ServerIdentifier.port(server)

      {:ok, sock} = :gen_tcp.connect(@localhost, port, [:binary, active: true])

      packet = Packet.encode(
        %Packet{type: :call,
          identifier: "foobar",
          payload: {:from, :ping}})

      :gen_tcp.send(sock, packet)

      assert_receive {:reply, :pong, _ }

      assert {:ok, %Packet{type: :reply, payload: {:pong, :from}}} =
        Packet.decode(receive do {:tcp, _, packet} -> packet end)
    end

    test "an unidentified packet gets rejected" do
      {:ok, server} = ServerIdentifier.start_link(self())
      {:ok, port} = ServerIdentifier.port(server)

      {:ok, sock} = :gen_tcp.connect(@localhost, port, [:binary, active: true])

      packet = Packet.encode(
        %Packet{type: :call,
          payload: {:from, :ping}})

      :gen_tcp.send(sock, packet)

      refute_receive {:reply, :pong, _ }

      assert {:ok, %Packet{type: :error}} =
        Packet.decode(receive do {:tcp, _, packet} -> packet end)
    end

    test "an misidentified packet gets rejected" do
      {:ok, server} = ServerIdentifier.start_link(self())
      {:ok, port} = ServerIdentifier.port(server)

      {:ok, sock} = :gen_tcp.connect(@localhost, port, [:binary, active: true])

      packet = Packet.encode(
        %Packet{type: :call,
          identifier: "barquux",
          payload: {:from, :ping}})

      :gen_tcp.send(sock, packet)

      refute_receive {:reply, :pong, _ }

      assert {:ok, %Packet{type: :error}} =
        Packet.decode(receive do {:tcp, _, packet} -> packet end)
    end
  end

  defmodule ServerSafe do
    use Erps.Server, safe: true

    def start_link(test_pid) do
      Erps.Server.start_link(__MODULE__, test_pid)
    end

    def init(test_pid), do: {:ok, test_pid}

    def handle_call(:ping, _from, test_pid) do
      send(test_pid, {:reply, :pong, test_pid})
    end
  end

  @packet_foobarquux <<4, 0::(63 * 8), 14::32,
    131, 100, 0, 10, 102, 111, 111, 98, 97, 114, 113, 117, 117, 120>>

  describe "for a server that's protected with safe" do
    test "sending a safe payload succeeds" do
      {:ok, server} = ServerSafe.start_link(self())
      {:ok, port} = ServerSafe.port(server)

      {:ok, sock} = :gen_tcp.connect(@localhost, port, [:binary, active: true])

      packet = Packet.encode(
        %Packet{type: :call,
          payload: {:from, :ping}})

      :gen_tcp.send(sock, packet)

      assert_receive {:reply, :pong, _ }

      assert {:ok, %Packet{type: :reply, payload: {:pong, :from}}} =
        Packet.decode(receive do {:tcp, _, packet} -> packet end)
    end

    test "sending an unsafe payload fails" do
      {:ok, server} = ServerSafe.start_link(self())
      {:ok, port} = ServerSafe.port(server)

      {:ok, sock} = :gen_tcp.connect(@localhost, port, [:binary, active: true])

      :gen_tcp.send(sock, @packet_foobarquux)

      refute_receive {:reply, :pong, _}

      assert {:ok, %Packet{type: :error}} =
        Packet.decode(receive do {:tcp, _, packet} -> packet end)
    end
  end

  defmodule ServerVerificationLocal do
    use Erps.Server, verification: :verification

    def start_link(test_pid) do
      Erps.Server.start_link(__MODULE__, test_pid)
    end

    def init(test_pid), do: {:ok, test_pid}

    def handle_call(:ping, _from, test_pid) do
      send(test_pid, {:reply, :pong, test_pid})
    end

    @hmac_key fn -> Enum.random(?A..?Z) end |> Stream.repeatedly |> Enum.take(16) |> List.to_string
    @hmac_secret :crypto.strong_rand_bytes(32)

    def hmac_key, do: @hmac_key

    def signature(binary) do
      :crypto.mac(:hmac, :sha256, @hmac_secret, binary)
    end

    def verification(binary, @hmac_key, signature) do
      :crypto.mac(:hmac, :sha256, @hmac_secret, binary) == signature
    end
  end

  describe "for a server that's got verification" do
    @tag :one
    test "a local function can be used for verification" do
      {:ok, server} = ServerVerificationLocal.start_link(self())
      {:ok, port} = ServerVerificationLocal.port(server)

      {:ok, sock} = :gen_tcp.connect(@localhost, port, [:binary, active: true])

      packet = Packet.encode(
        %Packet{type: :call,
          hmac_key: ServerVerificationLocal.hmac_key(),
          payload: {:from, :ping}},
        sign_with: &ServerVerificationLocal.signature/1)

      :gen_tcp.send(sock, packet)

      assert_receive {:reply, :pong, _ }, 500

      assert {:ok, %Packet{type: :reply, payload: {:pong, :from}}} =
        Packet.decode(receive do {:tcp, _, packet} -> packet end)
    end

    test "when a local function is used for verification sending an unverified payload fails" do
      {:ok, server} = ServerVerificationLocal.start_link(self())
      {:ok, port} = ServerVerificationLocal.port(server)

      {:ok, sock} = :gen_tcp.connect(@localhost, port, [:binary, active: true])

      packet = Packet.encode(
        %Packet{type: :call,
          payload: {:from, :ping}})

      :gen_tcp.send(sock, packet)

      refute_receive {:reply, :pong, _}, 500

      assert {:ok, %Packet{type: :error}} =
        Packet.decode(receive do {:tcp, _, packet} -> packet end)
    end
  end

end
