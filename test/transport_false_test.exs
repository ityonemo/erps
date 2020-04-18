defmodule ErpsTest.TransportFalseTest do
  use ExUnit.Case, async: true

  @moduletag :transport_false

  defmodule Server do
    use Erps.Server
    def start_link do
      Erps.Server.start_link(
        __MODULE__,
        self(),
        transport: false)
    end

    @impl true
    def init(cb), do: {:ok, cb}

    @impl true
    def handle_call(data, _, cb) do
      {:reply, data, cb}
    end

    @impl true
    def handle_cast(data, cb) do
      send(cb, data)
      {:noreply, cb}
    end

    @impl true
    def handle_info(data, cb) do
      send(cb, data)
      {:noreply, cb}
    end
  end

  describe "when a server's port is set to false" do
    test "handle_call/3 is normal" do
      {:ok, server} = Server.start_link()
      assert :foo = GenServer.call(server, :foo)
    end

    test "handle_cast/2 is normal" do
      {:ok, server} = Server.start_link()
      GenServer.cast(server, :bar)
      assert_receive :bar
    end

    test "handle_info/2 is normal" do
      {:ok, server} = Server.start_link()
      send(server, :baz)
      assert_receive :baz
    end
  end

end
