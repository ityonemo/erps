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

        def start_link(val), do: Erps.Server.start_link(__MODULE__, val, [])
        def init(val), do: {:ok, val}

        def port(srv), do: Erps.Server.port(srv)
        def push(srv, val), do: Erps.Server.push(srv, val)
      end
    end
  end

  setup context do
    server_module = Module.concat(context.module, "Server")
    {:ok, srv} = server_module.start_link(:ok)
    {:ok, server: srv}
  end

end
