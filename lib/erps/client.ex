defmodule Erps.Client do
  defmacro __using__(_opts) do
    quote do
      @behaviour Erps.Client
    end
  end

  defstruct [:module, :socket, :server, :port, :data]

  def start(module, state, opts) do
    inner_opts = Keyword.take(opts, [:server, :port])
    GenServer.start(__MODULE__, {module, state, inner_opts}, opts)
  end

  def start_link(module, state, opts) do
    inner_opts = Keyword.take(opts, [:server, :port])
    GenServer.start_link(__MODULE__, {module, state, inner_opts}, opts)
  end

  def init({module, start, opts}) do
    port = opts[:port]
    server = opts[:server]
    with {:ok, socket} <- :gen_tcp.connect(server, port, [:binary, active: true]),
         {:ok, init_state} <- module.init(start) do
      {:ok, struct(__MODULE__, [module: module, socket: socket, data: init_state] ++ opts)}
    end
  end

  def call(srv, val), do: GenServer.call(srv, val)
  def cast(srv, val), do: GenServer.cast(srv, val)

  def handle_call(val, from, state) do
    :gen_tcp.send(state.socket, :erlang.term_to_binary({:"$call", from, val}))
    {:noreply, state}
  end

  def handle_cast(val, state) do
    :gen_tcp.send(state.socket, :erlang.term_to_binary({:"$cast", val}))
    {:noreply, state}
  end

  def handle_info({:tcp, _socket, data}, state) do
    case :erlang.binary_to_term(data) do
      {:"$push", value} ->
        state.module.handle_push(value, state.data)
      {reply, from} -> GenServer.reply(from, reply)
    end
    {:noreply, state}
  end
  def handle_info({:tcp_closed, socket}, state = %{socket: socket}) do
    {:stop, :tcp_closed, state}
  end

end
