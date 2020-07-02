defmodule ErpsTest.ClientConnectionTest do
  #
  # tests to make sure that an unconnected client works as expected.
  #

  use ExUnit.Case, async: true

  @moduletag :connection

  defmodule Client do
    use Erps.Client, reconnect: 100

    @localhost IP.localhost()

    def start(port) do
      Erps.Client.start(__MODULE__, self(), server: @localhost, port: port)
    end
    def start_link(port) do
      Erps.Client.start_link(__MODULE__, self(), server: @localhost, port: port)
    end

    def init(test_pid), do: {:ok, test_pid}
  end

  describe "when a client connects and fails to find a server" do

    test "calls result in disconnected atom" do
      port = Enum.random(10_000..30_000)
      {:ok, client} = Client.start(port)

      assert :disconnected == GenServer.call(client, :foo, 300)
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
end
