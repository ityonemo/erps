defmodule ErpsTest.Callbacks.ClientInitTest do
  use ExUnit.Case, async: true
  use ErpsTest.ClientCase

  defmodule Client do
    use Erps.Client

    @localhost IP.localhost()

    def start_link(port, async_pid) do
      Erps.Client.start_link(__MODULE__,
        async_pid, server: @localhost, port: port)
    end

    @impl true
    def init(async_pid) do
      send(async_pid, {:init, self()})
      receive do any -> any end
    end

    @impl true
    def handle_push(:ping, test_pid) do
      send(test_pid, :ping)
      {:noreply, test_pid}
    end
  end

  defp springload_init(init_result) do
    Task.async(fn ->
      receive do
        {:init, client_pid} ->
          send(client_pid, init_result)
      end
    end)
  end

  describe "the init/1 function" do
    test "can return {:ok, state}", %{port: port} do
      # set up an async which springloads an initialization response
      async = springload_init({:ok, self()})
      Client.start_link(port, async.pid)

      Process.sleep(50)

      # verify that all is well.
      Erps.Server.push(server(), :ping)
      assert_receive :ping
    end

    test "can just ignore", %{port: port} do
      async = springload_init(:ignore)
      assert :ignore = Client.start_link(port, async.pid)
    end

    test "can stop", %{port: port} do
      async = springload_init({:stop, :abnormal})
      assert {:error, :abnormal} = Client.start_link(port, async.pid)
    end
  end

end
