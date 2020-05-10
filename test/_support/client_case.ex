# credo:disable-for-this-file Credo.Check.Readability.ModuleDoc

defmodule ErpsTest.ClientCase do

  #
  # Test Case for developing client tests.  Note this
  # means that a minimal SERVER is created.
  #

  use ExUnit.CaseTemplate

  using do
    quote do
      defmodule Server do
        use Erps.Server

        def start_link(test_pid, opts) do
          Erps.Server.start_link(__MODULE__, test_pid, opts)
        end

        def init(test_pid) do
          send(test_pid, {:server, self()})
          {:ok, test_pid}
        end
      end

      defp server do
        receive do {:server, server_pid} -> server_pid end
      end
    end
  end

  alias Erps.Daemon

  setup context do
    server_module = Module.concat(context.module, "Server")
    {:ok, daemon} = Daemon.start_link(server_module, self())
    {:ok, port} = Daemon.port(daemon)
    {:ok, port: port}
  end

end
