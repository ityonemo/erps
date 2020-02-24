defmodule Erps.Client do

  @behaviour GenServer

  defmacro __using__(_opts) do
    quote do
      @behaviour Erps.Client
    end
  end

  defstruct [:module, :socket, :server, :port, :data]

  @typep state :: %__MODULE__{
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

  @impl true
  def init({module, start, opts}) do
    port = opts[:port]
    server = opts[:server]
    case :gen_tcp.connect(server, port, [:binary, active: true]) do
      {:ok, socket} ->
        start
        |> module.init()
        |> process_init([module: module, socket: socket] ++ opts)
    end
  end

  def call(srv, val), do: GenServer.call(srv, val)
  def cast(srv, val), do: GenServer.cast(srv, val)

  @impl true
  def handle_call(val, from, state) do
    :gen_tcp.send(state.socket, :erlang.term_to_binary({:"$call", from, val}))
    {:noreply, state}
  end

  @impl true
  def handle_cast(val, state) do
    :gen_tcp.send(state.socket, :erlang.term_to_binary({:"$cast", val}))
    {:noreply, state}
  end

  @impl true
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

  @spec push_impl(push :: term, state) :: {:noreply, state} | {:stop, term, state}
  defp push_impl(push, state = %{module: module}) do
    if function_exported?(module, :handle_push, 2) do
      push
      |> module.handle_push(state.data)
      |> process_noreply(state)
    else
      {:noreply, state}
    end
  end

  @impl true
  @spec terminate(reason, state) :: term
    when reason: :normal | :shutdown | {:shutdown, term}
  def terminate(reason, state = %{module: module}) do
    if function_exported?(module, :terminate, 2) do
      module.terminate(reason, state.data)
    end
  end

  @impl true
  def handle_continue(continuation, state = %{module: module}) do
    continuation
    |> module.handle_continue(state.data)
    |> process_noreply(state)
  end

  #############################################################################
  ## Adapters

  defp process_init(init_resp, parameters) do
    case init_resp do
      {:ok, data} ->
        {:ok, struct(__MODULE__, [data: data] ++ parameters)}
      {:ok, data, timeout_or_continue} ->
        {:ok, struct(__MODULE__, [data: data] ++ parameters), timeout_or_continue}
      any -> any
    end
  end

  defp process_noreply(noreply_resp, state) do
    case noreply_resp do
      {:noreply, data} ->
        {:noreply, %{state | data: data}}
      {:noreply, data, timeout_or_continue} ->
        {:noreply, %{state | data: data}, timeout_or_continue}
      {:stop, reason, new_state} ->
        {:stop, reason, %{state | data: new_state}}
      any -> any
    end
  end

  #############################################################################
  ## API Definition

  @callback init(init_arg :: term()) ::
    {:ok, state}
    | {:ok, state, timeout() | :hibernate | {:continue, term()}}
    | :ignore
    | {:stop, reason :: any()}
    when state: term

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

  @callback handle_info(msg :: :timeout | term(), state :: term()) ::
    {:noreply, new_state}
    | {:noreply, new_state, timeout() | :hibernate | {:continue, term()}}
    | {:stop, reason :: term(), new_state}
    when new_state: term()

  @callback  handle_continue(continue :: term(), state :: term()) ::
    {:noreply, new_state}
    | {:noreply, new_state, timeout() | :hibernate | {:continue, term()}}
    | {:stop, reason :: term(), new_state}
    when new_state: term()

  @doc """
  Invoked when the client is about to exit, usually due to `handle_push/2`
  sending a `{:stop, reason, new_state}` tuple, but also if the TCP
  connection happens to go down.
  """
  @callback terminate(reason, state :: term) :: term
  when reason: :normal | :shutdown | {:shutdown, term}

  @optional_callbacks handle_push: 2, terminate: 2
end
