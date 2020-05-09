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

        def start_link(state), do: Erps.Server.start_link(__MODULE__, state, [])
        def init(state), do: {:ok, state}
      end
    end
  end

  setup context do
    server_module = Module.concat(context.module, "Server") 
    {:ok, srv} = server_module.start_link(:ok) 
    {:ok, server: srv} 
  end

end
