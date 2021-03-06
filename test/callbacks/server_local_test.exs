defmodule ErpsTest.Callbacks.ServerLocalTest do

  use ExUnit.Case, async: true

  @moduletag :server

  # tests on Erps.Server to make sure that it correctly responds
  # to local calls.

  defmodule Server do
    use Erps.Server

    def start(test_pid, opts \\ []) do
      Erps.Server.start(__MODULE__, test_pid, opts)
    end

    @impl true
    def init(state), do: {:ok, state}

    def reply(srv, to_whom, what) do
      GenServer.call(srv, {:reply, to_whom, what})
    end

    @impl true
    # Utilities
    def handle_call({:reply, to_whom, what}, _from, test_pid) do
      Erps.Server.reply(to_whom, what)
      {:reply, :ok, test_pid}
    end
    def handle_call(:ping, _, test_pid) do
      send(test_pid, :ping)
      {:reply, :ok, test_pid}
    end

    # instrumentable responses
    def handle_call(call, from, test_pid) do
      # wait for an instumented response.
      send(test_pid, {:called, from, call})
      receive do any when any != :accept -> any end
    end
    @impl true
    def handle_cast(cast, test_pid) do
      # wait for an instumented response.
      send(test_pid, {:casted, cast})
      receive do any when any != :accept -> any end
    end
    @impl true
    def handle_info(info, test_pid) do
      # wait for an instrumented response
      send(test_pid, {:sent, info})
      receive do any when any != :accept -> any end
    end

    @impl true
    def handle_continue(continue, test_pid) do
      send(test_pid, continue)
      {:noreply, test_pid}
    end
  end

  setup do
    {:ok, server} = Server.start(self())
    {:ok, server: server}
  end

  describe "when instrumented with a call response" do
    test "a local client can also be returned the call result", %{server: server} do
      ping_task = Task.async(fn -> receive do any -> any end end)
      async = Task.async(fn -> GenServer.call(server, :foo) end)
      receive do {:called, _, :foo} -> send(server, {:reply, :foo, ping_task.pid}) end
      assert :foo == Task.await(async)
      GenServer.call(server, :ping)
      assert :ping == Task.await(ping_task)
    end

    test "a local client can send the server into a continuation", %{server: server} do
      ping_task = Task.async(fn -> receive do any -> any end end)
      async = Task.async(fn -> GenServer.call(server, :foo) end)
      receive do {:called, _, :foo} -> send(server, {:reply, :foo, ping_task.pid, {:continue, :continued}}) end
      assert :foo == Task.await(async)
      assert :continued == Task.await(ping_task)
    end

    test "a local client can send the server into a noreply", %{server: server} do
      ping_task = Task.async(fn -> receive do any -> any end end)
      async = Task.async(fn -> GenServer.call(server, :foo) end)
      callback_from = receive do
        {:called, from, :foo} ->
          send(server, {:noreply, ping_task.pid})
          from
      end
      # force a reply back.
      Server.reply(server, callback_from, :foo)
      assert :foo == Task.await(async)
      GenServer.call(server, :ping)
      assert :ping == Task.await(ping_task)
    end

    test "a local client can send the server into a noreply with a continuation", %{server: server} do
      ping_task = Task.async(fn -> receive do any -> any end end)
      async = Task.async(fn -> GenServer.call(server, :foo) end)
      callback_from = receive do
        {:called, from, :foo} ->
          send(server, {:noreply, ping_task.pid, {:continue, :continued}})
          from
      end
      # force a reply back.
      Server.reply(server, callback_from, :foo)
      assert :foo = Task.await(async)
      assert :continued = Task.await(ping_task)
    end

    test "a local client can stop the server with reply", %{server: server} do
      Process.monitor(server)
      async = Task.async(fn -> GenServer.call(server, :foo) end)
      receive do {:called, _, :foo} -> send(server, {:stop, :normal, :foo, self()}) end
      assert :foo == Task.await(async)
      Process.sleep(20)

      assert_receive {:DOWN, _, _, ^server, :normal}
    end

    test "a local client can stop the server without reply", %{server: server} do
      Process.monitor(server)
      async = Task.async(fn ->
        try do
          GenServer.call(server, :foo)
        catch
          :exit, _reason -> :died
        end
      end)
      receive do {:called, _, :foo} -> send(server, {:stop, :normal, self()}) end
      assert :died == Task.await(async)
      assert_receive {:DOWN, _, _, ^server, :normal}
    end
  end

  describe "when instrumented with a cast response" do
    test "a local client can send a cast", %{server: server} do
      ping_task = Task.async(fn -> receive do any -> any end end)
      assert :ok = GenServer.cast(server, :foo)
      receive do {:casted, :foo} -> send(server, {:noreply, ping_task.pid}) end
      GenServer.call(server, :ping)
      assert :ping == Task.await(ping_task)
    end

    test "a local client can send a cast with continuation", %{server: server} do
      ping_task = Task.async(fn -> receive do any -> any end end)
      assert :ok = GenServer.cast(server, :foo)
      receive do {:casted, :foo} -> send(server, {:noreply, ping_task.pid, {:continue, :continued}}) end
      assert :continued == Task.await(ping_task)
    end

    test "a local client can cast a stop", %{server: server} do
      Process.monitor(server)
      assert :ok = GenServer.cast(server, :foo)
      receive do {:casted, :foo} -> send(server, {:stop, :normal, self()}) end
      Process.sleep(20)
      assert_receive {:DOWN, _, _, ^server, :normal}
    end
  end

  describe "when instrumented with an info response" do
    test "a local client can send a info", %{server: server} do
      ping_task = Task.async(fn -> receive do any -> any end end)
      send(server, :foo)
      receive do {:sent, :foo} -> send(server, {:noreply, ping_task.pid}) end
      GenServer.call(server, :ping)
      assert :ping == Task.await(ping_task)
    end

    test "a local client can send a info with a continuation", %{server: server} do
      ping_task = Task.async(fn -> receive do any -> any end end)
      send(server, :foo)
      receive do {:sent, :foo} -> send(server, {:noreply, ping_task.pid, {:continue, :continued}}) end
      GenServer.call(server, :ping)
      assert :continued == Task.await(ping_task)
    end

    test "a local client can send a stop", %{server: server} do
      Process.monitor(server)
      send(server, :foo)
      receive do {:sent, :foo} -> send(server, {:stop, :normal, self()}) end
      Process.sleep(20)
      assert_receive {:DOWN, _, _, ^server, :normal}
    end
  end
end
