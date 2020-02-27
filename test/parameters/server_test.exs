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

    @tag :one
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
end
