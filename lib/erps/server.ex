defmodule Erps.Server do
  defmacro __using__(opts) do

    decode_opts = Keyword.take(opts, [:identifier, :versions, :safe])

    Module.register_attribute(__CALLER__.module, :decode_opts, persist: true)

    quote do
      @behaviour Erps.Server

      # define a set of "magic functions".
      def port(srv), do: Erps.Server.port(srv)
      def push(srv, push), do: Erps.Server.push(srv, push)
      def connections(srv), do: Erps.Server.connections(srv)
      def disconnect(srv, port), do: Erps.Server.disconnect(srv, port)

      @decode_opts unquote(decode_opts)
    end
  end

  defstruct [:module, :data, :port, :socket, :decode_opts,
    connections: []]

  @behaviour GenServer

  alias Erps.Packet

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

    decode_opts = module.__info__(:attributes)[:decode_opts]

    case :gen_tcp.listen(port, [:binary, active: true, reuseaddr: true]) do
      {:ok, socket} ->
        # kick off the accept loop.
        Process.send_after(self(), :accept, 0)
        param
        |> module.init
        |> process_init(module: module, port: port,
          socket: socket, decode_opts: decode_opts)
      {:error, what} ->
        {:stop, what}
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
    tcp_data = Packet.encode(%Packet{
      type: :push,
      payload: push
    })
    Enum.each(state.connections, &:gen_tcp.send(&1, tcp_data))
    {:reply, :ok, state}
  end

  #############################################################################
  ## GenServer wrappers

  def call(srv, content, timeout \\ 5000), do: GenServer.call(srv, content, timeout)

  def reply({:remote, socket, from}, reply) do
    tcp_data = Packet.encode(%Packet{type: :reply, payload: {reply, from}})
    :gen_tcp.send(socket, tcp_data)
  end
  def reply(local_client, reply), do: GenServer.reply(local_client, reply)

  #############################################################################
  # router

  @impl true
  def handle_call(:"$port", _from, state), do: port_impl(state)
  def handle_call(:"$connections", _from, state), do: connections_impl(state)
  def handle_call({:"$disconnect", port}, _from, state), do: disconnect_impl(port, state)
  def handle_call({:"$push", push}, _from, state) do
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
    case Packet.decode(bin_data, state.decode_opts) do
      {:ok, %Packet{type: :keepalive}} ->
        {:noreply, state}
      {:ok, %Packet{type: :call, payload: {from, data}}} ->
        remote_from = {:remote, socket, from}
        data
        |> module.handle_call(remote_from, state.data)
        |> process_call(remote_from, state)
      {:ok, %Packet{type: :cast, payload: data}} ->
        data
        |> module.handle_cast(state.data)
        |> process_noreply(state)
      {:error, any} ->
        tcp_data = Packet.encode(%Packet{type: :error, payload: any})
        :gen_tcp.send(socket, tcp_data)
        {:noreply, state}
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

  @impl true
  def terminate(reason, state = %{module: module}) do
    if function_exported?(module, :terminate, 2) do
      module.terminate(reason, state.data)
    end
  end

  #############################################################################
  ## ADAPTERS
  ##
  ## these functions do the hard work of connecting output responses by the
  ## target module to be compatible with the responses by gen_servers.

  defp process_init(init_result, init_params) do
    case init_result do
      {:ok, data} ->
        {:ok, struct(__MODULE__, [data: data] ++ init_params)}
      {:ok, data, timeout_or_continue} ->
        {:ok, struct(__MODULE__, [data: data] ++ init_params), timeout_or_continue}
      any ->
        any
    end
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

  @callback init(init_arg :: term()) ::
    {:ok, state}
    | {:ok, state, timeout() | :hibernate | {:continue, term()}}
    | :ignore
    | {:stop, reason :: any()}
    when state: term

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

  @callback  handle_continue(continue :: term(), state :: term()) ::
    {:noreply, new_state}
    | {:noreply, new_state, timeout() | :hibernate | {:continue, term()}}
    | {:stop, reason :: term(), new_state}
    when new_state: term()

  @callback terminate(reason, state :: term) :: term
  when reason: :normal | :shutdown | {:shutdown, term}

  @optional_callbacks handle_call: 3, handle_cast: 2, handle_info: 2, handle_continue: 2, terminate: 2
end
