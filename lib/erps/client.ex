defmodule Erps.Client do
  defmacro __using__(_opts) do
    quote do
      @behaviour Erps.Client
    end
  end

  defstruct [:module, :socket]

  def start(module, target, opts) do
    inner_opts = Keyword.take(opts, [:port])
    GenServer.start(__MODULE__, {module, target, inner_opts}, opts)
  end

  def start_link(module, target, opts) do
    inner_opts = Keyword.take(opts, [:port])
    GenServer.start_link(__MODULE__, {module, target, inner_opts}, opts)
  end

  def init({module, target, inner_opts}) do
    with {:ok, socket} <- :gen_tcp.connect(target, inner_opts[:port], [:binary, active: true]) do
      {:ok, %__MODULE__{module: module, socket: socket}}
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
    {reply, from} = :erlang.binary_to_term(data)
    GenServer.reply(from, reply)
    {:noreply, state}
  end
  def handle_info({:tcp_closed, socket}, state = %{socket: socket}) do
    {:stop, :tcp_closed, state}
  end

end
