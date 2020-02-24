defmodule ErpsTest.OtpTest do
  use ExUnit.Case, async: true

  defmodule TestClient do
    use Erps.Client

    @localhost {127, 0, 0, 1}

    def start(test_pid, port: port) do
      Erps.Client.start(__MODULE__, test_pid, server: @localhost, port: port)
    end

    def start_link(test_pid, port: port) do
      Erps.Client.start_link(__MODULE__, test_pid, server: @localhost, port: port)
    end

    def handle_push(:die, state), do: {:stop, :die, state}
    def handle_push(:ping, test_pid) do
      send(test_pid, :ping)
      {:noreply, test_pid}
    end

    def init(start), do: {:ok, start}
  end

  defmodule TestServer do
    use Erps.Server

    def start(state) do
      Erps.Server.start(__MODULE__, state, [])
    end

    def start_link(state) do
      Erps.Server.start_link(__MODULE__, state, [])
    end

    def init(state), do: {:ok, state}
  end

  describe "when you kill the client" do
    test "the server is okay" do
      {:ok, server} = TestServer.start_link(:ok)
      {:ok, port} = Erps.Server.port(server)
      {:ok, client} = TestClient.start(self(), port: port)

      Process.sleep(20)
      Process.exit(client, :kill)
      Process.sleep(50)

      assert Process.alive?(server)
    end
  end

  describe "when you kill the server" do
    test "client will get killed" do
      {:ok, server} = TestServer.start(:ok)
      {:ok, port} = Erps.Server.port(server)
      {:ok, client} = TestClient.start(self(), port: port)

      Process.sleep(20)
      Process.exit(server, :kill)
      Process.sleep(50)

      refute Process.alive?(client)
    end
  end
end
