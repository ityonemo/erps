defmodule Erps.Server do

  if Mix.env() in [:dev, :test] do
    @default_strategy Erps.TCP
  else
    @default_strategy Erps.TLS
  end

  defmacro __using__(opts) do

    decode_opts = Keyword.take(opts, [:identifier, :versions, :safe])
    verification = opts[:verification]

    Module.register_attribute(__CALLER__.module, :decode_opts, persist: true)
    Module.register_attribute(__CALLER__.module, :verification, persist: true)

    if opts[:identifier] && :erlang.size(opts[:identifier]) >= 12 do
      raise CompileError,
        file: __CALLER__.file,
        line: __CALLER__.line,
        description: "identifier size too large"
    end

    quote do
      @behaviour Erps.Server

      # define a set of "magic functions".
      def port(srv), do: Erps.Server.port(srv)
      def push(srv, push), do: Erps.Server.push(srv, push)
      def connections(srv), do: Erps.Server.connections(srv)
      def disconnect(srv, port), do: Erps.Server.disconnect(srv, port)

      @decode_opts unquote(decode_opts)
      @verification unquote(verification)
    end
  end

  defstruct [:module, :data, :port, :socket, :decode_opts, :filter, :packet_type,
    ssl_opts: [],
    strategy: @default_strategy,
    connections: []]

  @behaviour GenServer

  alias Erps.Packet

  def start(module, param, opts \\ []) do
    inner_opts = Keyword.take(opts, [:port, :strategy, :ssl_opts])
    GenServer.start(__MODULE__, {module, param, inner_opts}, opts)
  end

  def start_link(module, param, opts \\ []) do
    inner_opts = Keyword.take(opts, [:port, :strategy, :ssl_opts])
    GenServer.start_link(__MODULE__, {module, param, inner_opts}, opts)
  end

  @impl true
  def init({module, param, opts}) do
    port = opts[:port] || 0

    verification_opts = case module.__info__(:attributes)[:verification] do
      [nil] -> []
      [fun] when is_atom(fun) ->
        [verification: &apply(module, fun, [&1, &2, &3])]
      [{mod, fun}] ->
        [verification: &apply(mod, fun, [&1, &2, &3])]
    end

    decode_opts = module.__info__(:attributes)[:decode_opts]
    ++ verification_opts

    filter = if function_exported?(module, :filter, 2) do
      &module.filter/2
    else
      &default_filter/2
    end

    strategy = opts[:strategy] || @default_strategy
    listen_opts = [:binary, active: false, reuseaddr: true, ssl_opts: opts[:ssl_opts]]

    case strategy.listen(port, listen_opts) do
      {:ok, socket} ->
        server_opts = Keyword.merge(opts,
          module: module, port: port, socket: socket, decode_opts: decode_opts,
          filter: filter, strategy: strategy, packet_type: strategy.packet_type())

        # kick off the accept loop.
        Process.send_after(self(), :accept, 0)
        param
        |> module.init
        |> process_init(server_opts)
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

  def disconnect(srv, socket), do: GenServer.call(srv, {:"$disconnect", socket})
  defp disconnect_impl(socket, state = %{connections: connections}) do
    if socket in connections do
      :gen_tcp.close(socket)
      new_connections = Enum.reject(connections, &(&1 == socket))
      {:reply, :ok, %{state | connections: new_connections}}
    else
      {:reply, {:error, :enoent}, state}
    end
  end

  def push(srv, value), do: GenServer.call(srv, {:"$push", value})
  defp push_impl(push, state = %{strategy: strategy}) do
    tcp_data = Packet.encode(%Packet{
      type: :push,
      payload: push
    })
    Enum.each(state.connections, &strategy.send(&1, tcp_data))
    {:reply, :ok, state}
  end

  #############################################################################
  ## GenServer wrappers

  def reply(from, reply) do
    send(self(), {:"$reply", from, reply})
    :ok
  end

  defp do_reply({:remote, socket, from}, reply, %{strategy: strategy}) do
    tcp_data = Packet.encode(%Packet{type: :reply, payload: {reply, from}})
    strategy.send(socket, tcp_data)
  end
  defp do_reply(local_client, reply, _state), do: GenServer.reply(local_client, reply)

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

  @closed [:tcp_closed, :ssl_closed]

  @impl true
  def handle_info(:accept, state = %{strategy: strategy}) do
    Process.send_after(self(), :accept, 0)
    with {:ok, socket} <- strategy.accept(state.socket, 100),
         {:ok, upgrade} <- strategy.handshake(socket, state.ssl_opts) do
      {:noreply, %{state | connections: [upgrade | state.connections]}}
    else
      _any -> {:noreply, state}
    end
  end
  def handle_info({ptype, socket, bin_data},
      state = %{module: module, filter: filter, strategy: strategy, packet_type: ptype}) do

    case Packet.decode(bin_data, state.decode_opts) do
      {:ok, %Packet{type: :keepalive}} ->
        {:noreply, state}
      {:ok, %Packet{type: :call, payload: {from, data}}} ->
        remote_from = {:remote, socket, from}
        unless filter.(data, :call), do: throw {:error, "filtered"}

        data
        |> module.handle_call(remote_from, state.data)
        |> process_call(remote_from, state)
      {:ok, %Packet{type: :cast, payload: data}} ->

        unless filter.(data, :cast), do: throw {:error, "filtered"}

        data
        |> module.handle_cast(state.data)
        |> process_noreply(state)
      e = {:error, _any} ->
        throw e
    end
  catch
    {:error, any} ->
      tcp_data = Packet.encode(%Packet{type: :error, payload: any})
      strategy.send(socket, tcp_data)
      {:noreply, state}
  end
  def handle_info({closed, port}, state) when closed in @closed do
    {:noreply, %{state | connections: Enum.reject(state.connections, &(&1 == port))}}
  end
  def handle_info({:"$reply", from, reply}, state) do
    do_reply(from, reply, state)
    {:noreply, state}
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
        do_reply(from, reply, state)
        {:noreply, %{state | data: data}}
      {:reply, reply, data, timeout_or_continue} ->
        do_reply(from, reply, state)
        {:noreply, %{state | data: data}, timeout_or_continue}
      {:stop, reason, reply, data} ->
        do_reply(from, reply, state)
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

  defp default_filter(_, _), do: true

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

  @callback filter(mode :: Packet.type, payload :: term) :: boolean

  @optional_callbacks handle_call: 3, handle_cast: 2, handle_info: 2, handle_continue: 2,
    terminate: 2, filter: 2
end
