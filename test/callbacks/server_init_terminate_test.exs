defmodule ErpsTest.Callbacks.ServerInitTerminateTest do
  use ExUnit.Case, async: true

  @moduletag :server

  # tests on Erps.Server to make sure that it can correctly do
  # init and terminate calls.

  defmodule Server do
    def start_link(test_pid) do
      Erps.Server.start_link(__MODULE__, test_pid)
    end

    def init(test_pid) do
      send(test_pid, {:init, self()})
      receive do any -> any end
    end

    def handle_call(:ping, _from, test_pid) do
      send(test_pid, :ping)
      {:reply, :ok, test_pid}
    end

    def handle_continue(value, test_pid) do
      send(test_pid, value)
      {:noreply, test_pid}
    end
  end

  describe "the init/1 function" do
    test "can return {:ok, state}" do
      test_pid = self()
      async = Task.async(fn ->
        receive do {:init, srv} -> send(srv, {:ok, test_pid}) end
      end)
      {:ok, srv} = Server.start_link(async.pid)
      GenServer.call(srv, :ping)
      assert_receive :ping
    end

    test "can be sent into continue from init" do
      test_pid = self()
      async = Task.async(fn ->
        receive do {:init, srv} -> send(srv, {:ok, test_pid, {:continue, :continued}}) end
      end)
      {:ok, srv} = Server.start_link(async.pid)
      assert_receive :continued
      GenServer.call(srv, :ping)
      assert_receive :ping
    end
  end


end
