defmodule ErpsTest.Handlers.ServerTest do

  use ExUnit.Case, async: true
  use ErpsTest.ServerCase

  @moduletag :server

  defmodule Server do
    use Erps.Server

    def start_link(test_pid) do
      Erps.Server.start_link(__MODULE__, test_pid)
    end
    def init(val), do: {:ok, val}

    # TODO: make this automagical.
    def port(srv), do: Erps.Server.port(srv)

    def handle_call(_val, _from, test_pid) do
      # wait for a instumented response.
      send(test_pid, :called)
      receive do any -> any end
    end

    def handle_info(val, test_pid) do
      send(test_pid, val)
    end
  end

  setup do
    {:ok, server} = Server.start_link(self())
    {:ok, port} = Server.port(server)
    {:ok, client} = Client.start_link(self(), port)
    {:ok, client: client, server: server}
  end

  describe "when instrumented with a call :reply response" do
    test "the client receives a call ", %{client: client, server: server} do
      async = Task.async(fn -> Client.call(client, :foo) end)
      receive do :called -> send(server, {:reply, :foo, self()}) end
      assert :foo == Task.await(async)
    end

    test "an arbitrary process can also be returned the call ", %{client: client, server: server} do
      async = Task.async(fn -> GenServer.call(client, :foo) end)
      receive do :called -> send(server, {:reply, :foo, self()}) end
      assert :foo == Task.await(async)
    end
  end

end
