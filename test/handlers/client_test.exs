defmodule ErpsTest.ClientTest do
  use ExUnit.Case, async: true

  defmodule Server do
    use Erps.Server

    def start_link(val), do: Erps.Server.start_link(__MODULE__, val, [])
    def init(val), do: {:ok, val}

  end

  setup do
    {:ok, svr} = Server.start_link(:ok)
    {:ok, server: svr}
  end


  defmodule Client do

    use Erps.Client

    @localhost {127, 0, 0, 1}

    def start_link(svr) do
      {:ok, port} = Erps.Server.port(svr)
      Erps.Client.start_link(__MODULE__,
        :ok, server: @localhost, port: port)
    end
    def init(val), do: {:ok, val}

    def handle_push(msg, state) do
      if is_pid(state), do: send(state, :pong)
      msg
    end
  end

  describe "when instrumented with a handle_push response" do
    test "the client can process a {:noreply, state}", %{server: svr} do
      Client.start_link(svr)
      Process.sleep(20)
      Erps.Server.push(svr, {:noreply, self()})
      Erps.Server.push(svr, {:noreply, :clear})
      assert_receive :pong
    end

    test "the client can process a {:stop, reason, state}", %{server: svr} do
      {:ok, client} = Client.start_link(svr)
      Process.sleep(20)
      Erps.Server.push(svr, {:stop, :normal, :ok})
      Process.sleep(20)
      refute Process.alive?(client)
    end
  end

end
