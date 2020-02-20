defmodule ErpsTest.PushTest do
  use ExUnit.Case, async: true

  @moduletag :push
  # makes sure that we can handle push results

  defmodule TestClient do
    use Erps.Client

    @localhost {127, 0, 0, 1}

    def start_link(test_pid, port) do
      Erps.Client.start_link(
        __MODULE__,
        test_pid,
        server: @localhost, port: port)
    end
    def init(test_pid), do: {:ok, test_pid}

    def handle_push(:push, test_pid) do
      send(test_pid, :pushed)
      {:noreply, test_pid}
    end
  end

  defmodule TestServer do
    use Erps.Server

    def start_link(state) do
      Erps.Server.start_link(__MODULE__, state, [])
    end

    def init(state), do: {:ok, state}

    def push(srv), do: Erps.Server.push(srv, :push)
  end

  test "servers respond when sent a push signal" do
    {:ok, srv} = TestServer.start_link(nil)
    {:ok, port} = Erps.Server.port(srv)
    TestClient.start_link(self(), port)
    Process.sleep(10)
    TestServer.push(srv)
    assert_receive :pushed
  end
end
