defmodule ErpsTest.PushTest do
  use ExUnit.Case, async: true
  use ErpsTest.ClientCase

  @moduletag :push
  # makes sure that we can handle push results

  defmodule Client do
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

  test "servers respond when sent a push signal" do
    {:ok, srv} = Server.start_link(nil)
    {:ok, port} = Server.port(srv)

    Client.start_link(self(), port)
    Process.sleep(20)
    Server.push(srv, :push)
    assert_receive :pushed
  end
end
