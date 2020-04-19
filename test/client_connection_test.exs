defmodule ErpsTest.ClientConnectionTest do
  #
  # tests to make sure that an unconnected client works as expected.
  #

  use ExUnit.Case, async: true

  @moduletag :connection

  defmodule Client do
    use Erps.Client, reconnect: 100

    @localhost {127, 0, 0, 1}

    def start(port) do
      Erps.Client.start(__MODULE__, self(), server: @localhost, port: port)
    end
    def start_link(port) do
      Erps.Client.start_link(__MODULE__, self(), server: @localhost, port: port)
    end

    def init(test_pid), do: {:ok, test_pid}
  end

  describe "when a client connects and fails to find a server" do
    test "calls result in throws" do
      port = Enum.random(10_000..30_000)
      {:ok, client} = Client.start(port)

      error = try do
        GenServer.call(client, :foo, 300)
      catch
        :exit, err ->
          err
      end

      assert {{%RuntimeError{}, _}, _} = error
    end

    test "casts don't fault" do
      port = Enum.random(10_000..30_000)
      {:ok, client} = Client.start(port)
      Process.monitor(client)

      GenServer.cast(client, :foo)

      refute_receive {:DOWN, _, _, ^client, _}, 500
      Process.exit(client, :kill)
    end
  end

  defmodule Server do
    use Erps.Server

    def start_link(port) do
      Erps.Server.start(__MODULE__, self(), port: port)
    end

    def init(test_pid), do: {:ok, test_pid}

    # just reflect calls back.
    def handle_call(any, _from, state), do: {:reply, any, state}
  end

  test "clients can reconnect to servers" do
    port = Enum.random(10_000..30_000)
    {:ok, client} = Client.start_link(port)

    # give it 750 milliseconds
    Process.sleep(750)

    Server.start_link(port)

    # give the client plenty of time to reconnect
    Process.sleep(150)

    assert :foo == GenServer.call(client, :foo, 500)
  end
end
