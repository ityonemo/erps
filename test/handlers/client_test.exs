defmodule ErpsTest.ClientTest do
  use ExUnit.Case, async: true
  use ErpsTest.ClientCase

  defmodule Client do

    use Erps.Client

    @localhost {127, 0, 0, 1}

    def start(svr) do
      {:ok, port} = Erps.Server.port(svr)
      Erps.Client.start(__MODULE__,
        :ok, server: @localhost, port: port)
    end
    def start_link(svr) do
      {:ok, port} = Erps.Server.port(svr)
      Erps.Client.start_link(__MODULE__,
        :ok, server: @localhost, port: port)
    end
    def init(val), do: {:ok, val}

    @impl true
    def handle_push(msg, state) do
      if is_pid(state), do: send(state, :pong)
      msg
    end

    @impl true
    def terminate(reason, state) do
      if is_pid(state), do: send(state, reason)
    end
  end

  describe "when instrumented with a handle_push response" do
    test "the client can process a {:noreply, state}", %{server: svr} do
      Client.start_link(svr)
      Process.sleep(20)
      Server.push(svr, {:noreply, self()})
      Server.push(svr, {:noreply, :clear})
      assert_receive :pong
    end

    test "the client can process a {:stop, reason, state}", %{server: svr} do
      {:ok, client} = Client.start_link(svr)
      Process.sleep(20)
      Server.push(svr, {:stop, :normal, :ok})
      Process.sleep(20)
      refute Process.alive?(client)
    end
  end

  describe "the terminate/2 callback is called" do
    test "when the server pushes a stop command", %{server: svr} do
      Client.start(svr)
      Process.sleep(20)
      Server.push(svr, {:stop, :normal, self()})
      assert_receive :normal
    end

    test "when the server disconnects", %{server: svr} do
      Client.start(svr)
      Process.sleep(20)
      # instrument a pid into the client, using server push.
      Server.push(svr, {:noreply, self()})
      Process.sleep(20)
      [client_port] = Server.connections(svr)
      Server.disconnect(svr, client_port)
      Process.sleep(20)
      assert_receive :tcp_closed
    end
  end

end
