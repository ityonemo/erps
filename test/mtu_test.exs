defmodule ErpsTest.MtuTest do
  # test that sending content that is larger than the network
  # mtu still works.

  use ExUnit.Case, async: true

  defmodule Client do
    use Erps.Client

    @localhost {127, 0, 0, 1}

    def start_link(port) do
      Erps.Client.start_link(__MODULE__, self(), server: @localhost, port: port)
    end

    def init(test_pid), do: {:ok, test_pid}

    def send_data(srv, data), do: GenServer.call(srv, {:send, data})

    def handle_push(push, test_pid) do
      send(test_pid, push)
      {:noreply, test_pid}
    end

  end

  defmodule Server do
    use Erps.Server

    def start_link(_) do
      Erps.Server.start_link(__MODULE__, self(), [])
    end

    def init(test_pid), do: {:ok, test_pid}

    def push_data(srv, data), do: Erps.Server.push(srv, {:push, data})

    def handle_call(sent = {:send, _data}, _from, test_pid) do
      send(test_pid, sent)
      {:reply, :ok, test_pid}
    end
  end

  describe "An Erps server" do
    test "can accept a call of size bigger than the MTU" do
      {:ok, server} = Server.start_link(nil)
      {:ok, port} = Erps.Server.port(server)
      {:ok, client} = Client.start_link(port)

      data = <<0::10240 * 8>>

      assert :ok = Client.send_data(client, data)
      assert_receive {:send, ^data}
    end

    test "can send a push of size bigger than the MTU" do
      {:ok, server} = Server.start_link(nil)
      {:ok, port} = Erps.Server.port(server)
      {:ok, _client} = Client.start_link(port)

      data = <<0::10240 * 8>>
      Process.sleep(100)

      assert :ok = Server.push_data(server, data)
      assert_receive {:push, ^data}
    end
  end
end
