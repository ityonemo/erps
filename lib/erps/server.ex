defmodule Erps.Server do
  defmacro __using__(_opts) do
    quote do
      @behaviour Erps.Server

      # define a set of "magic functions".
      def push(srv, push), do: Erps.Server.push(srv, push)
      def connections(srv), do: Erps.Server.connections(srv)
      def disconnect(srv, port), do: Erps.Server.disconnect(srv, port)
    end
  end

  defstruct [:module, :data, :port, :socket,
    connections: []]

  @behaviour GenServer

  def start(module, param, opts \\ []) do
    inner_opts = Keyword.take(opts, [:port])
    GenServer.start(__MODULE__, {module, param, inner_opts}, opts)
  end

  def start_link(module, param, opts \\ []) do
    inner_opts = Keyword.take(opts, [:port])
    GenServer.start_link(__MODULE__, {module, param, inner_opts}, opts)
  end

  @impl true
  def init({module, param, inner_opts}) do
    port = inner_opts[:port] || 0
    with {:ok, socket} <- :gen_tcp.listen(port, [:binary, active: true]),
         {:ok, init_state} <- module.init(param) do
      Process.send_after(self(), :accept, 0)
      {:ok, %__MODULE__{module: module, data: init_state, port: port, socket: socket}}
    end
  end

  #############################################################################
  ## API

  def port(srv), do: GenServer.call(srv, :"$port")
  defp port_impl(state) do
    {:reply, :inet.port(state.socket), state}
  end

  def connections(srv), do: GenServer.call(srv, :"$connections")
  defp connections_impl(state) do
    {:reply, state.connections, state}
  end

  def disconnect(srv, port), do: GenServer.call(srv, {:"$disconnect", port})
  defp disconnect_impl(port, state = %{connections: connections}) do
    if port in connections do
      :gen_tcp.close(port)
      new_connections = Enum.reject(connections, &(&1 == port))
      {:reply, :ok, %{state | connections: new_connections}}
    else
      {:reply, {:error, :enoent}, state}
    end
  end

  def push(srv, value), do: GenServer.call(srv, {:"$push", value})
  defp push_impl(push, state) do
    bindata = :erlang.term_to_binary(push)
    Enum.each(state.connections, &:gen_tcp.send(&1, bindata))
    {:reply, :ok, state}
  end

  #############################################################################
  ## GenServer wrappers

  def call(srv, content, timeout \\ 5000), do: GenServer.call(srv, content, timeout)

  def reply({:remote, socket, from}, reply) do
    :gen_tcp.send(socket, :erlang.term_to_binary({reply, from}))
  end
  def reply(local_client, reply), do: GenServer.reply(local_client, reply)

  #############################################################################
  # router

  @impl true
  def handle_call(:"$port", _from, state), do: port_impl(state)
  def handle_call(:"$connections", _from, state), do: connections_impl(state)
  def handle_call({:"$disconnect", port}, _from, state), do: disconnect_impl(port, state)
  def handle_call(push = {:"$push", _}, _from, state) do
    push_impl(push, state)
  end
  def handle_call(call, from, state = %{module: module}) do
    call
    |> module.handle_call(from, state.data)
    |> process_call(from, state)
  end

  @impl true
  def handle_cast(cast, state = %{module: module}) do
    cast
    |> module.handle_cast(state.data)
    |> process_noreply(state)
  end

  @impl true
  def handle_info(:accept, state) do
    new_state = case :gen_tcp.accept(state.socket, 100) do
      {:ok, socket} -> %{state | connections: [socket | state.connections]}
      _ -> state
    end
    Process.send_after(self(), :accept, 0)
    {:noreply, new_state}
  end
  def handle_info({:tcp, socket, bin_data}, state = %{module: module}) do
    case :erlang.binary_to_term(bin_data) do
      {:"$call", from, data} ->
        data
        |> module.handle_call(from, state.data)
        |> process_call({:remote, socket, from}, state)
      {:"$cast", data} ->
        data
        |> module.handle_cast(state.data)
        |> process_noreply(state)
    end
  end
  def handle_info({:tcp_closed, port}, state) do
    {:noreply, %{state | connections: Enum.reject(state.connections, &(&1 == port))}}
  end
  def handle_info(info_term, state = %{module: module}) do
    info_term
    |> module.handle_info(state.data)
    |> process_noreply(state)
  end

  @impl true
  def handle_continue(continue_term, state = %{module: module}) do
    continue_term
    |> module.handle_continue(state.data)
    |> process_noreply(state)
  end

  defp process_call(call_result, from, state) do
    case call_result do
      {:reply, reply, data} ->
        reply(from, reply)
        {:noreply, %{state | data: data}}
      {:reply, reply, data, timeout_or_continue} ->
        reply(from, reply)
        {:noreply, %{state | data: data}, timeout_or_continue}
      {:stop, reason, reply, data} ->
        reply(from, reply)
        {:stop, reason, %{state | data: data}}
      any ->
        process_noreply(any, state)
    end
  end

  defp process_noreply(call_result, state) do
    case call_result do
      {:noreply, data} ->
        {:noreply, %{state | data: data}}
      {:noreply, data, timeout_or_continue} ->
        {:noreply, %{state | data: data}, timeout_or_continue}
      {:stop, reason, data} ->
        {:stop, reason, %{state | data: data}}
    end
  end

  #############################################################################
  ## BEHAVIOUR CALLBACKS

  @type from :: GenServer.from | {:remote, :inet.socket, GenServer.from}

  @callback handle_call(request :: term, from, state :: term) ::
    {:reply, reply, new_state}
    | {:reply, reply, new_state, timeout | :hibernate | {:continue, term}}
    | {:noreply, new_state}
    | {:noreply, new_state, timeout | :hibernate | {:continue, term}}
    | {:stop, reason, reply, new_state}
    | {:stop, reason, new_state}
    when reply: term, new_state: term, reason: term

  @callback handle_cast(request :: term(), state :: term()) ::
    {:noreply, new_state}
    | {:noreply, new_state, timeout() | :hibernate | {:continue, term()}}
    | {:stop, reason :: term(), new_state}
    when new_state: term()

  @callback handle_info(msg :: :timeout | term(), state :: term()) ::
    {:noreply, new_state}
    | {:noreply, new_state, timeout() | :hibernate | {:continue, term()}}
    | {:stop, reason :: term(), new_state}
    when new_state: term()

  @optional_callbacks handle_call: 3, handle_cast: 2, handle_info: 2
end
