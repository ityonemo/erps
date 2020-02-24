defmodule ErpsTest.Callbacks.ServerInitTerminateTest do
  use ExUnit.Case, async: true

  @moduletag :server

  # tests on Erps.Server to make sure that it can correctly do
  # init and terminate calls.

  defmodule Server do

    def start(test_pid) do
      Erps.Server.start(__MODULE__, test_pid)
    end
    def start_link(test_pid) do
      Erps.Server.start_link(__MODULE__, test_pid)
    end

    @impl true
    def init(test_pid) do
      send(test_pid, {:init, self()})
      receive do
        any when any != :accept -> any
      after 10 -> {:ok, test_pid}
      end
    end

    @impl true
    def handle_call(:ping, _from, test_pid) do
      send(test_pid, :ping)
      {:reply, :ok, test_pid}
    end

    @impl true
    def handle_continue(value, test_pid) do
      send(test_pid, value)
      {:noreply, test_pid}
    end

    @impl true
    def handle_cast(:stop, test_pid) do
      {:stop, :normal, test_pid}
    end

    @impl true
    def terminate(reason, test_pid) do
      send(test_pid, reason)
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

    test "server can be sent into ignore from init" do
      test_pid = self()
      async = Task.async(fn ->
        receive do {:init, srv} -> send(srv, :ignore) end
      end)
      assert :ignore == Server.start_link(async.pid)
    end

    test "server can be stopped by init" do
      test_pid = self()
      async = Task.async(fn ->
        receive do {:init, srv} -> send(srv, {:stop, "foo"}) end
      end)
      assert {:error, "foo"} == Server.start_link(async.pid)
    end
  end

  describe "the terminate/2 function" do
    test "traps a termination from a {:stop, _, _} cast result" do
      test_pid = self()
      async = Task.async(fn ->
        receive do {:init, srv} -> send(srv, {:ok, test_pid}) end
      end)
      {:ok, srv} = Server.start(async.pid)
      GenServer.cast(srv, :stop)
      assert_receive :normal
    end
  end
end
