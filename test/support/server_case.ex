defmodule ErpsTest.ServerCase do

  #
  # Test Case for developing server tests.  Note this
  # means that a minimal CLIENT is created.
  #

  use ExUnit.CaseTemplate

  using do
    quote do
      defmodule Client do
        use Erps.Client

        @localhost {127, 0, 0, 1}

        def start_link(test_pid, port) do
          Erps.Client.start_link(__MODULE__, test_pid, server: @localhost, port: port)
        end
        def init(test_pid), do: {:ok, test_pid}

        def handle_push(val, test_pid) do
          send(test_pid, val)
          {:noreply, test_pid}
        end

        def call(srv, call), do: Erps.Client.call(srv, call)
      end
    end
  end

end
