defmodule ErpsTest.Handlers.ServerTest do

  use ExUnit.Case, async: true
  use ErpsTest.ServerCase

  @moduletag :server

  defmodule Server do
    use Erps.Server

    def start(test_pid) do
      Erps.Server.start(__MODULE__, test_pid)
    end
    def init(val), do: {:ok, val}

    # TODO: make this automagical.
    def port(srv), do: Erps.Server.port(srv)

    def reply(srv, to_whom, what) do
      GenServer.call(srv, {:reply, to_whom, what})
    end

    def handle_call({:reply, to_whom, what}, _from, test_pid) do
      Erps.Server.reply(to_whom, what)
      {:reply, :ok, test_pid}
    end
    def handle_call(val, from, test_pid) do
      # wait for a instumented response.
      send(test_pid, {:called, from, val})
      receive do any -> any end
    end

    def handle_continue(value, test_pid) do
      send(test_pid, value)
      {:noreply, test_pid}
    end
  end

  setup do
    {:ok, server} = Server.start(self())
    {:ok, port} = Server.port(server)
    {:ok, client} = Client.start(self(), port)
    {:ok, client: client, server: server}
  end

  describe "when instrumented with a call response" do
    test "a remote client receives a call result", %{client: client, server: server} do
      async = Task.async(fn -> Client.call(client, :foo) end)
      receive do {:called, _, :foo} -> send(server, {:reply, :foo, self()}) end
      assert :foo == Task.await(async)
    end

    test "a local client can also be returned the call result", %{server: server} do
      async = Task.async(fn -> GenServer.call(server, :foo) end)
      receive do {:called, _, :foo} -> send(server, {:reply, :foo, self()}) end
      assert :foo == Task.await(async)
    end

    test "a remote client can send the server into a continuation", %{client: client, server: server} do
      async = Task.async(fn -> Client.call(client, :foo) end)
      receive do {:called, _, :foo} -> send(server, {:reply, :foo, self(), {:continue, :continued}}) end
      assert :foo == Task.await(async)
      assert_receive :continued
    end

    test "a local client can send the server into a continuation", %{server: server} do
      async = Task.async(fn -> GenServer.call(server, :foo) end)
      receive do {:called, _, :foo} -> send(server, {:reply, :foo, self(), {:continue, :continued}}) end
      assert :foo == Task.await(async)
      assert_receive :continued
    end

    test "a remote client can send the server into a noreply", %{client: client, server: server} do
      async = Task.async(fn -> Client.call(client, :foo) end)
      callback_from = receive do
        {:called, from, :foo} ->
          send(server, {:noreply, self()})
          from
      end
      # force a reply back.
      Server.reply(server, callback_from, :foo)
      assert :foo == Task.await(async)
    end

    test "a local client can send the server into a noreply", %{server: server} do
      async = Task.async(fn -> GenServer.call(server, :foo) end)
      callback_from = receive do
        {:called, from, :foo} ->
          send(server, {:noreply, self()})
          from
      end
      # force a reply back.
      Server.reply(server, callback_from, :foo)
      assert :foo == Task.await(async)
    end

    test "a remote client can send the server into a noreply with a continuation", %{client: client, server: server} do
      async = Task.async(fn -> Client.call(client, :foo) end)
      callback_from = receive do
        {:called, from, :foo} ->
          send(server, {:noreply, self(), {:continue, :continued}})
          from
      end
      # force a reply back.
      Server.reply(server, callback_from, :foo)
      assert :foo == Task.await(async)
      assert_receive :continued
    end

    test "a local client can send the server into a noreply with a continuation", %{server: server} do
      async = Task.async(fn -> GenServer.call(server, :foo) end)
      callback_from = receive do
        {:called, from, :foo} ->
          send(server, {:noreply, self(), {:continue, :continued}})
          from
      end
      # force a reply back.
      Server.reply(server, callback_from, :foo)
      assert :foo == Task.await(async)
      assert_receive :continued
    end

    test "a remote client can stop the server with reply", %{client: client, server: server} do
      async = Task.async(fn -> Client.call(client, :foo) end)
      receive do {:called, _, :foo} -> send(server, {:stop, :normal, :foo, self()}) end
      assert :foo == Task.await(async)
      refute Process.alive?(server)
    end

    test "a local client can stop the server with reply", %{server: server} do
      async = Task.async(fn -> GenServer.call(server, :foo) end)
      receive do {:called, _, :foo} -> send(server, {:stop, :normal, :foo, self()}) end
      assert :foo == Task.await(async)
      refute Process.alive?(server)
    end

    test "a remote client can stop the server without reply", %{client: client, server: server} do
      async = Task.async(fn ->
        try do
          Client.call(client, :foo)
        catch
          :exit, _value -> :died
        end
      end)
      receive do {:called, _, :foo} -> send(server, {:stop, :normal, self()}) end
      assert :died == Task.await(async)
      refute Process.alive?(server)
      refute Process.alive?(client)
    end

    test "a local client can stop the server without reply", %{server: server} do
      async = Task.async(fn ->
        try do
          GenServer.call(server, :foo)
        catch
          :exit, value -> :died
        end
      end)
      receive do {:called, _, :foo} -> send(server, {:stop, :normal, self()}) end
      assert :died == Task.await(async)
      refute Process.alive?(server)
    end
  end
end
