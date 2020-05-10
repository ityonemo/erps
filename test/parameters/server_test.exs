defmodule ErpsTest.Parameters.ServerTest do
  use ExUnit.Case, async: true

  @moduletag :parameters

  defmodule ServerVersion do
    use Erps.Server, versions: "~> 0.1.3"

    def start_link(test_pid) do
      Erps.Server.start_link(__MODULE__, test_pid)
    end

    def init(test_pid), do: {:ok, test_pid}

    def handle_cast(:ping, test_pid) do
      send(test_pid, :pong)
      {:noreply, test_pid}
    end
  end

  alias Erps.Daemon
  alias Erps.Packet

  @localhost {127, 0, 0, 1}
  describe "when the server is versioned" do
    test "a properly versioned packet gets accepted" do
      {:ok, daemon} = Daemon.start_link(ServerVersion, self())
      {:ok, port} = Daemon.port(daemon)

      {:ok, sock} = :gen_tcp.connect(@localhost, port, [:binary, active: true])
      Process.sleep(150)

      packet = Packet.encode(
        %Packet{type: :cast,
          version: %Version{major: 0, minor: 1, patch: 3, pre: []},
          payload: :ping})

      :gen_tcp.send(sock, packet)

      assert_receive :pong
    end

    test "an unversioned packet gets rejected" do
      {:ok, daemon} = Daemon.start_link(ServerVersion, self())
      {:ok, port} = Daemon.port(daemon)

      {:ok, sock} = :gen_tcp.connect(@localhost, port, [:binary, active: true])
      Process.sleep(150)

      packet = Packet.encode(
        %Packet{type: :cast, payload: :ping})

      :gen_tcp.send(sock, packet)

      refute_receive :pong

      assert_receive {:tcp, _, <<?e, ?r, ?p, ?s, _size :: 32>> <> packet}
      assert {:ok, %Packet{type: :error}} = Packet.decode(packet)
    end

    test "an old version packet gets rejected" do
      {:ok, daemon} = Daemon.start_link(ServerVersion, self())
      {:ok, port} = Daemon.port(daemon)

      {:ok, sock} = :gen_tcp.connect(@localhost, port, [:binary, active: true])
      Process.sleep(150)

      packet = Packet.encode(
        %Packet{type: :cast,
          version: %Version{major: 0, minor: 0, patch: 3, pre: []},
          payload: :ping})

      :gen_tcp.send(sock, packet)

      refute_receive :pong

      assert_receive {:tcp, _, <<?e, ?r, ?p, ?s, _size :: 32>> <> packet}
      assert {:ok, %Packet{type: :error}} = Packet.decode(packet)
    end

    test "an incompatibly versioned packet gets rejected" do
      {:ok, daemon} = Daemon.start_link(ServerVersion, self())
      {:ok, port} = Daemon.port(daemon)

      {:ok, sock} = :gen_tcp.connect(@localhost, port, [:binary, active: true])
      Process.sleep(150)

      packet = Packet.encode(
        %Packet{type: :cast,
          version: %Version{major: 2, minor: 1, patch: 3, pre: []},
          payload: :ping})

      :gen_tcp.send(sock, packet)

      refute_receive :pong

      assert_receive {:tcp, _, <<?e, ?r, ?p, ?s, _size :: 32>> <> packet}
      assert {:ok, %Packet{type: :error}} = Packet.decode(packet)
    end
  end

  defmodule ServerIdentifier do
    use Erps.Server, identifier: "foobar"

    def start_link(test_pid) do
      Erps.Server.start_link(__MODULE__, test_pid)
    end

    def init(test_pid), do: {:ok, test_pid}

    def handle_cast(_, test_pid) do
      send(test_pid, :pong)
      {:noreply, test_pid}
    end
  end

  describe "when the server has an identifier" do
    test "a properly identified packet gets accepted" do
      {:ok, daemon} = Daemon.start_link(ServerIdentifier, self())
      {:ok, port} = Daemon.port(daemon)

      {:ok, sock} = :gen_tcp.connect(@localhost, port, [:binary, active: true])
      Process.sleep(150)

      packet = Packet.encode(
        %Packet{type: :cast,
          identifier: "foobar",
          payload: {:from, :ping}})

      :gen_tcp.send(sock, packet)

      assert_receive :pong
    end

    test "an unidentified packet gets rejected" do
      {:ok, daemon} = Daemon.start_link(ServerIdentifier, self())
      {:ok, port} = Daemon.port(daemon)

      {:ok, sock} = :gen_tcp.connect(@localhost, port, [:binary, active: true])
      Process.sleep(150)

      packet = Packet.encode(
        %Packet{type: :cast,
          payload: {:from, :ping}})

      :gen_tcp.send(sock, packet)

      refute_receive {:reply, :pong, _ }

      assert_receive {:tcp, _, <<?e, ?r, ?p, ?s, _size :: 32>> <> packet}

      assert {:ok, %Packet{type: :error}} = Packet.decode(packet)
    end

    test "an misidentified packet gets rejected" do
      {:ok, daemon} = Daemon.start_link(ServerIdentifier, self())
      {:ok, port} = Daemon.port(daemon)

      {:ok, sock} = :gen_tcp.connect(@localhost, port, [:binary, active: true])
      Process.sleep(150)

      packet = Packet.encode(
        %Packet{type: :cast,
          identifier: "barquux",
          payload: {:from, :ping}})

      :gen_tcp.send(sock, packet)

      refute_receive {:reply, :pong, _ }

      assert_receive {:tcp, _, <<?e, ?r, ?p, ?s, _size :: 32>> <> packet}

      assert {:ok, %Packet{type: :error}} = Packet.decode(packet)
    end
  end

  #############################################################################
  ## SERVER TERM SAFETY

  defmodule ServerSafe do
    use Erps.Server

    def start_link(test_pid, opts \\ []) do
      Erps.Server.start_link(__MODULE__, test_pid, opts)
    end

    def init(test_pid) do
      send(test_pid, {:server, self()})
      {:ok, test_pid}
    end

    def handle_cast(_, test_pid) do
      send(test_pid, :pong)
      {:noreply, test_pid}
    end
  end

  defmodule ServerUnSafe do
    use Erps.Server, safe: false

    def start_link(test_pid) do
      Erps.Server.start_link(__MODULE__, test_pid)
    end

    def init(test_pid) do
      send(test_pid, {:server, self()})
      {:ok, test_pid}
    end

    def handle_cast(_, test_pid) do
      send(test_pid, :pong)
      {:noreply, test_pid}
    end
  end

  @magic_cookie <<?e, ?r, ?p, ?s>>
  @packet_header <<8, 0::87 * 8>>  # "CAST" packet
  @binary_ping <<131, 100, 0, 4, 112, 105, 110, 103>>
  @binary_foobarquux <<131, 100, 0,
    10, 102, 111, 111, 98, 97, 114, 113, 117, 117, 120>>
  @binary_foobazquux <<131, 100, 0,
    10, 102, 111, 111, 98, 97, 122, 113, 117, 117, 120>>

  def encapsulate_send(socket, binary) do
    :gen_tcp.send(socket, [
      @magic_cookie,
      <<:erlang.size(binary) :: 32>>,
      @packet_header,
      binary])
  end

  describe "for a server that's protected with safe" do
    test "sending a safe payload succeeds" do
      {:ok, daemon} = Daemon.start_link(ServerSafe, self())
      {:ok, port} = Daemon.port(daemon)

      {:ok, sock} = :gen_tcp.connect(@localhost, port, [:binary, active: true])

      assert_receive {:server, _server}

      encapsulate_send(sock, @binary_ping)

      assert_receive :pong
    end

    test "sending an unsafe payload fails" do
      {:ok, server_sup} = DynamicSupervisor.start_link(strategy: :one_for_one)
      {:ok, daemon} = Daemon.start_link(ServerSafe, self(), server_supervisor: server_sup)
      {:ok, port} = Daemon.port(daemon)

      {:ok, sock} = :gen_tcp.connect(@localhost, port, [:binary, active: true])

      assert_receive {:server, server}

      encapsulate_send(sock, @binary_foobarquux)

      refute_receive :pong

      # make sure the server has been torched.
      refute Process.alive?(server)
    end
  end

  describe "for a server that's not protected with safe" do
    test "sending an unsafe payload succeeds" do
      {:ok, daemon} = Daemon.start_link(ServerUnSafe, self())
      {:ok, port} = Daemon.port(daemon)

      {:ok, sock} = :gen_tcp.connect(@localhost, port, [:binary, active: true])

      assert_receive {:server, _server}

      encapsulate_send(sock, @binary_foobazquux)

      assert_receive :pong
    end
  end

end
