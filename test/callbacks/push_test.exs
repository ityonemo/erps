defmodule ErpsTest.Callbacks.PushTest do
  use ExUnit.Case, async: true
  use ErpsTest.ClientCase

  @moduletag :push
  # makes sure that we can handle push results

  defmodule Client do
    use Erps.Client

    @localhost IP.localhost()

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

  test "servers respond when sent a push signal", %{port: port} do
    Client.start_link(self(), port)
    Process.sleep(20)

    Erps.Server.push(server(), :push)

    assert_receive :pushed
  end
end
