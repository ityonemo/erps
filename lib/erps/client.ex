defmodule Erps.Client do
  defmacro __using__(_opts) do
    quote do
      @behaviour Erps.Client
    end
  end

  defstruct [:module, :socket, :server, :port, :data]

  @typep t :: %__MODULE__{
    module: module,
    socket: :gen_tcp.socket,
    server: :inet.address,
    port: :inet.port_number,
    data: term,
  }

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
        push_impl(value, state)
      {reply, from} ->
        GenServer.reply(from, reply)
        {:noreply, state}
    end
  end
  def handle_info({:tcp_closed, socket}, state = %{socket: socket}) do
    {:stop, :tcp_closed, state}
  end

  defp push_impl(value, state = %{module: module}) do
    value
    |> module.handle_push(state.data)
    |> case do
      {:noreply, new_state} ->
        {:noreply, %{state | data: new_state}}
      {:stop, reason, new_state} ->
        {:stop, reason, %{state | data: new_state}}
      any -> any
      # this lets us fail with a standard gen_server failure message.
    end
  end

  @impl true
  @spec terminate(reason, t) :: term
    when reason: :normal | :shutdown | {:shutdown, term}
  def terminate(reason, state = %{module: module}) do
    if function_exported?(module, :terminate, 2) do
      module.terminate(reason, state.data)
    end
  end

  #############################################################################
  ## API Definition

  @doc """
  Invoked to handle `Erps.Server.push/2` messages.

  `push` is the push message sent by a push/2 and `state` is the current
  state of the `Erps.Client`.

  ### Return codes
  - `{:noreply, new_state}` continues the loop with new state `new_state`
  - `{:stop, reason, new_state}` terminates the loop, passing `new_state`
    to `c:terminate/2`, if it's implemented.
  """
  @callback handle_push(push :: term, state :: term) ::
    {:noreply, new_state}
    | {:stop, reason :: term, new_state}
  when new_state: term

  @doc """
  Invoked when the client is about to exit, usually due to `handle_push/2`
  sending a `{:stop, reason, new_state}` tuple, but also if the TCP
  connection happens to go down.
  """
  @callback terminate(reason, state :: term) :: term
  when reason: :normal | :shutdown | {:shutdown, term}

  @optional_callbacks handle_push: 2
end
