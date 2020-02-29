defmodule ErpsTest.Callbacks.ServerFilterTest do

  use ExUnit.Case, async: true

  defmodule DoublerServer do
    use Erps.Server

    def start_link(test_pid) do
      Erps.Server.start_link(__MODULE__, test_pid)
    end

    @impl true
    def init(test_pid), do: {:ok, test_pid}

    @impl true
    def handle_call({:double, number}, _from, test_pid) do
      {:reply, number * 2, test_pid}
    end

    @impl true
    def handle_cast({:sendme, number}, test_pid) do
      send(test_pid, number)
      {:noreply, test_pid}
    end

    @impl true
    def filter({:double, value}, :call), do: value != 42
    def filter({:sendme, value}, :cast), do: value != 0
  end

  defmodule DoublerClient do
    use Erps.Client

    @localhost {127, 0, 0, 1}
    def start_link(port) do
      Erps.Client.start_link(__MODULE__, self(), server: @localhost, port: port)
    end
    def init(test_pid), do: {:ok, test_pid}

    def double(srv, number), do: GenServer.call(srv, {:double, number}, 250)
    def sendme(srv, number), do: GenServer.cast(srv, {:sendme, number})
  end

  test "when you double a sane number it works" do
    {:ok, server} = DoublerServer.start_link(self())
    {:ok, port} = DoublerServer.port(server)
    {:ok, client} = DoublerClient.start_link(port)

    Process.sleep(20)

    assert 94 == DoublerClient.double(client, 47)
    assert 0 == DoublerClient.double(client, 0)
  end

  test "when you double a filtered number it fails" do
    {:ok, server} = DoublerServer.start_link(self())
    {:ok, port} = DoublerServer.port(server)
    {:ok, client} = DoublerClient.start_link(port)

    Process.sleep(20)

    assert (try do
      DoublerClient.double(client, 42)
      false
    catch
      :exit, {:timeout, _} ->
        true
    end)
  end

  test "casts are filtered on a different channel" do
    {:ok, server} = DoublerServer.start_link(self())
    {:ok, port} = DoublerServer.port(server)
    {:ok, client} = DoublerClient.start_link(port)

    Process.sleep(20)

    DoublerClient.sendme(client, 47)
    assert_receive 47, 500
    DoublerClient.sendme(client, 42)
    assert_receive 42, 500
  end

  test "casts are filtered on a different channel and can fail" do
    {:ok, server} = DoublerServer.start_link(self())
    {:ok, port} = DoublerServer.port(server)
    {:ok, client} = DoublerClient.start_link(port)

    Process.sleep(20)

    DoublerClient.sendme(client, 0)
    refute_receive 0, 500
  end

end
