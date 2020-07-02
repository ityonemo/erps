defmodule ErpsTest.Callbacks.ClienttConnectTest do
  use ExUnit.Case, async: true
  use ErpsTest.ClientCase

  defmodule Client do
    use Erps.Client

    @localhost IP.localhost()

    def start_link(port, test_pid) do
      Erps.Client.start_link(__MODULE__,
        test_pid, server: @localhost, port: port)
    end

    @impl true
    def init(test_pid) do
      {:ok, test_pid}
    end

    @impl true
    def handle_connect(_socket, test_pid) do
      send(test_pid, :connected)
      {:noreply, test_pid}
    end
  end

  describe "the handle_connect/1 function" do
    @tag :one
    test "is triggered on connection", %{port: port} do
      Client.start_link(port, self())

      assert_receive :connected
    end
  end

end
