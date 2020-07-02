defmodule ErpsTest.Callbacks.ClientTest do
  use ExUnit.Case, async: true
  use ErpsTest.ClientCase

  @moduletag :client

  defmodule Client do

    use Erps.Client

    @localhost IP.localhost()

    def start(port, test_pid) do
      Erps.Client.start(__MODULE__,
        test_pid, server: @localhost, port: port)
    end
    def start_link(port, test_pid) do
      Erps.Client.start_link(__MODULE__,
        test_pid, server: @localhost, port: port)
    end

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_push(push, test_pid) do
      instrumented(:push, push, test_pid)
    end

    @impl true
    def handle_info(info, test_pid) do
      instrumented(:info, info, test_pid)
    end

    @impl true
    def terminate(reason, test_pid) do
      instrumented(:terminate, reason, test_pid)
    end

    defp instrumented(what, content, test_pid) do
      send(test_pid, {what, self(), content})
      receive do {:inject, content} -> content end
    end
  end

  defp inject(injection) do
    {what, client_pid, content} = receive do
      triple = {_, _, _} -> triple
    after 500 -> raise "timeout"
    end
    send(client_pid, {:inject, injection})
    {what, content}
  end


  describe "when instrumented with a handle_push response" do
    test "the client can process a {:noreply, state}", %{port: port} do
      Client.start_link(port, self())
      svr = server()
      Process.sleep(20)
      Server.push(svr, :foo)
      {:push, :foo} = inject({:noreply, self()})
      Server.push(svr, :bar)
      {:push, :bar} = inject({:noreply, self()})
    end

    test "the client can process a mutating {:noreply, state}", %{port: port} do
      Client.start_link(port, self())
      svr = server()
      Process.sleep(20)

      task = Task.async(fn -> inject({:noreply, self()}) end)

      Server.push(svr, :foo)
      {:push, :foo} = inject({:noreply, task.pid})
      Server.push(svr, :bar)
      {:push, :bar} = Task.await(task)
    end

    test "the client can process a {:stop, reason, state}", %{port: port} do
      {:ok, client} = Client.start(port, self())
      Process.monitor(client)
      Process.sleep(20)
      Server.push(server(), :foo)
      {:push, :foo} = inject({:stop, :normal, self()})
      {:terminate, :normal} = inject("unimportant term")
      assert_receive {:DOWN, _, _, ^client, :normal}
    end
  end

  describe "when instrumented with a handle_info response" do
    test "the client can process a {:noreply, state}", %{port: port} do
      {:ok, client} = Client.start_link(port, self())
      Process.sleep(20)
      send(client, :foo)
      {:info, :foo} = inject({:noreply, self()})
    end

    test "the client can process a stop message", %{port: port} do
      {:ok, client} = Client.start_link(port, self())
      Process.monitor(client)
      Process.sleep(20)
      send(client, :foo)
      {:info, :foo} = inject({:stop, :normal, self()})
      {:terminate, :normal} = inject("unimportant term")
      assert_receive {:DOWN, _, _, ^client, :normal}
    end
  end

  describe "the terminate/2 callback is called" do
    test "when the server disconnects", %{port: port} do
      {:ok, client} = Client.start(port, self())
      Process.monitor(client)
      Process.sleep(20)
      # instrument a pid into the client, using server push.
      Server.disconnect(server())
      {:terminate, :disconnected} = inject("unimportant term")
      assert_receive {:DOWN, _, _, ^client, :disconnected}
    end
  end

end
