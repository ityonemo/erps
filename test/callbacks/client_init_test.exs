defmodule ErpsTest.Callbacks.ClientInitTest do
  use ExUnit.Case, async: true
  use ErpsTest.ClientCase

  defmodule Client do
    use Erps.Client

    @localhost {127, 0, 0, 1}

    def start_link(svr, test_pid) do
      {:ok, port} = Server.port(svr)
      Erps.Client.start_link(__MODULE__,
        test_pid, server: @localhost, port: port)
    end

    @impl true
    def init(test_pid) do
      send(test_pid, {:init, self()})
      receive do any -> any end
    end

    @impl true
    def handle_push(:ping, test_pid) do
      send(test_pid, :ping)
      {:noreply, test_pid}
    end

    @impl true
    def handle_continue(continue, test_pid) do
      send(test_pid, continue)
      {:noreply, test_pid}
    end
  end

  describe "the init/1 function" do
    test "can return {:ok, state}", %{server: server} do
      test_pid = self()
      async = Task.async(fn ->
        receive do {:init, client_pid} -> send(client_pid, {:ok, test_pid}) end
      end)
      Client.start_link(server, async.pid)

      Process.sleep(50)

      Server.push(server, :ping)
      assert_receive :ping
    end

    test "can send into a continuation", %{server: server} do
      test_pid = self()
      async = Task.async(fn ->
        receive do
          {:init, client_pid} -> send(client_pid, {:ok, test_pid, {:continue, :continued}})
        end
      end)

      Client.start_link(server, async.pid)

      assert_receive :continued
    end

    test "can just ignore", %{server: server} do
      async = Task.async(fn ->
        receive do {:init, client_pid} -> send(client_pid, :ignore) end
      end)
      assert :ignore = Client.start_link(server, async.pid)
    end

    test "can stop", %{server: server} do
      async = Task.async(fn ->
        receive do {:init, client_pid} -> send(client_pid, {:stop, :abnormal}) end
      end)
      assert {:error, :abnormal} = Client.start_link(server, async.pid)
    end
  end

end
