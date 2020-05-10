defmodule ErpsTest.Callbacks.ServerRemoteTest do
  use ExUnit.Case, async: true
  use ErpsTest.ServerCase

  # tests on Erps.Server to make sure that it correctly responds
  # to remote calls.

  alias Erps.Daemon

  @moduletag :server

  defmodule Server do
    use Erps.Server

    def start(test_pid, opts \\ []) do
      Erps.Server.start(__MODULE__, test_pid, opts)
    end

    def start_link(test_pid, opts \\ []) do
      Erps.Server.start_link(__MODULE__, test_pid, opts)
    end

    @impl true
    def init(test_pid) do
      send(test_pid, {:server, self()})
      {:ok, test_pid}
    end

    def reply(to_whom, what), do: GenServer.reply(to_whom, what)

    @impl true
    # Utilities
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
    {:ok, daemon} = Daemon.start(Server, self())
    {:ok, port} = Daemon.port(daemon)
    {:ok, client} = Client.start(self(), port)

    server = receive do {:server, server} -> server end

    on_exit(fn ->
      if Process.alive?(server), do: Process.exit(server, :kill)
      if Process.alive?(client), do: Process.exit(client, :kill)
    end)

    {:ok, client: client, server: server}
  end

  describe "when instrumented with a call response" do
    test "a remote client receives a call result", %{client: client, server: server} do
      ping_task = Task.async(fn -> receive do any -> any end end)
      async = Task.async(fn -> Client.call(client, :foo) end)
      receive do {:called, _, :foo} -> send(server, {:reply, :foo, ping_task.pid}) end
      assert :foo == Task.await(async)
      GenServer.call(server, :ping)
      assert :ping == Task.await(ping_task)
    end

    test "a remote client can send the server into a continuation", %{client: client, server: server} do
      ping_task = Task.async(fn -> receive do any -> any end end)
      async = Task.async(fn -> Client.call(client, :foo) end)
      receive do {:called, _, :foo} -> send(server, {:reply, :foo, ping_task.pid, {:continue, :continued}}) end
      assert :foo == Task.await(async)
      assert :continued == Task.await(ping_task)
    end

    test "a remote client can send the server into a noreply", %{client: client, server: server} do
      ping_task = Task.async(fn -> receive do any -> any end end)
      async = Task.async(fn -> Client.call(client, :foo) end)
      callback_from = receive do
        {:called, from, :foo} ->
          send(server, {:noreply, ping_task.pid})
          from
      end
      # force a reply back.
      Server.reply(callback_from, :foo)
      assert :foo == Task.await(async)
      GenServer.call(server, :ping)
      assert :ping == Task.await(ping_task)
    end

    test "a remote client can send the server into a noreply with a continuation", %{client: client, server: server} do
      ping_task = Task.async(fn -> receive do any -> any end end)
      async = Task.async(fn -> Client.call(client, :foo) end)
      callback_from = receive do
        {:called, from, :foo} ->
          send(server, {:noreply, ping_task.pid, {:continue, :continued}})
          from
      end

      # force a reply back.
      Server.reply(callback_from, :foo)
      assert :foo == Task.await(async)
      assert :continued = Task.await(ping_task)
    end

    test "a remote client can stop the server with reply", %{client: client, server: server} do
      Process.monitor(server)
      async = Task.async(fn ->
        Client.call(client, :foo)
      end)

      receive do {:called, _, :foo} -> send(server, {:stop, :normal, :foo, self()}) end
      assert :foo == Task.await(async)
      assert_receive {:DOWN, _, _, ^server, :normal}
    end

    test "a remote client can stop the server without reply", %{client: client, server: server} do
      Process.monitor(client)
      Process.monitor(server)
      async = Task.async(fn ->
        try do
          Client.call(client, :foo)
        catch
          :exit, _reason -> :died
        end
      end)
      receive do {:called, _, :foo} -> send(server, {:stop, :normal, self()}) end
      assert :died == Task.await(async)
      assert_receive {:DOWN, _, _, ^server, :normal}
      assert_receive {:DOWN, _, _, ^client, :disconnected}
    end
  end

  describe "when instrumented with a cast response" do
    test "a remote client can send a cast", %{client: client, server: server} do
      ping_task = Task.async(fn -> receive do any -> any end end)
      assert :ok = Client.cast(client, :foo)
      receive do {:casted, :foo} -> send(server, {:noreply, ping_task.pid}) end
      GenServer.call(server, :ping)
      assert :ping == Task.await(ping_task)
    end

    test "a remote client can send a cast with continuation", %{client: client, server: server} do
      ping_task = Task.async(fn -> receive do any -> any end end)
      assert :ok = Client.cast(client, :foo)
      receive do {:casted, :foo} -> send(server, {:noreply, ping_task.pid, {:continue, :continued}}) end
      assert :continued == Task.await(ping_task)
    end

    test "a remote client can cast a stop", %{client: client, server: server} do
      Process.monitor(server)
      assert :ok = Client.cast(client, :foo)
      receive do {:casted, :foo} -> send(server, {:stop, :normal, self()}) end
      Process.sleep(20)
      assert_receive {:DOWN, _, _, ^server, :normal}
    end
  end
end
