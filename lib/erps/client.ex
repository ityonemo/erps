defmodule Erps.Client do

  @behaviour GenServer

  @zero_version %Version{major: 0, minor: 0, patch: 0, pre: []}

  if Mix.env() in [:dev, :test] do
    @default_strategy Erps.Strategy.Tcp
  else
    @default_strategy Erps.Strategy.Tls
  end

  # by default, attempt a reconnect every minute.
  @default_reconnect 60_000

  alias Erps.Packet

  defmacro __using__(opts) do
    version = if opts[:version] do
      Version.parse!(opts[:version])
    else
      @zero_version
    end

    if opts[:identifier] && :erlang.size(opts[:identifier]) >= 12 do
      raise CompileError,
        file: __CALLER__.file,
        line: __CALLER__.line,
        description: "identifier size too large"
    end

    options = Keyword.merge(opts, version: version)

    base_packet = Packet
    |> struct(options)
    |> Macro.escape

    Module.register_attribute(__CALLER__.module, :base_packet, persist: true)
    Module.register_attribute(__CALLER__.module, :encode_opts, persist: true)
    Module.register_attribute(__CALLER__.module, :hmac_key,    persist: true)
    Module.register_attribute(__CALLER__.module, :sign_with,   persist: true)
    Module.register_attribute(__CALLER__.module, :reconnect,   persist: true)

    encode_opts = Keyword.take(options, [:compressed])

    quote do
      @behaviour   Erps.Client
      @base_packet unquote(base_packet)
      @encode_opts unquote(encode_opts)
      @sign_with   unquote(options[:sign_with])
      @reconnect   unquote(options[:reconnect])
    end
  end

  # one minute keepalive interval.
  @default_keepalive 60_000

  defstruct [:module, :socket, :server, :port, :data, :base_packet,
    :encode_opts, :hmac_key, :signature, :reconnect, :packet_type,
    ssl_opts: [],
    keepalive: @default_keepalive,
    strategy: @default_strategy]

  @type hmac_function :: (() -> String.t)
  @type signing_function :: ((content :: binary, key :: binary) -> signature :: binary)

  @typep state :: %__MODULE__{
    module:      module,
    socket:      nil | :gen_tcp.socket,
    server:      :inet.address,
    port:        :inet.port_number,
    data:        term,
    base_packet: Packet.t,
    encode_opts: list,
    hmac_key:    nil | hmac_function,
    signature:   nil | signing_function,
    reconnect:   non_neg_integer,
    packet_type: :tcp | :ssl,
    ssl_opts:    keyword,
    keepalive:   timeout,
    strategy:    module
  }

  require Logger

  def start(module, state, opts) do
    inner_opts = Keyword.take(opts, [:server, :port, :strategy, :ssl_opts, :keepalive])
    GenServer.start(__MODULE__, {module, state, inner_opts}, opts)
  end

  def start_link(module, state, opts) do
    inner_opts = Keyword.take(opts, [:server, :port, :strategy, :ssl_opts, :keepalive])
    GenServer.start_link(__MODULE__, {module, state, inner_opts}, opts)
  end

  @impl true
  def init({module, start, opts}) do
    port = opts[:port]
    server = opts[:server]

    attributes = module.__info__(:attributes)
    [sign_with] = attributes[:sign_with]

    hmac_key = case attributes[:hmac_key] do
      [string] when is_binary(string) -> string
      [atom] when is_atom(atom) ->
        apply(module, atom, [])
      [{mod, fun}] ->
        apply(mod, fun, [])
      _ -> <<0::16 * 8>>
    end

    [base_packet] = attributes[:base_packet]

    encode_opts = attributes[:encode_opts] ++
    case sign_with do
      nil -> []
      fun when is_atom(fun) ->
        [sign_with: &apply(module, fun, [&1])]
      {mod, fun} ->
        [sign_with: &apply(mod, fun, [&1, hmac_key])]
    end

    ssl_opts = opts[:ssl_opts] || []
    keepalive = opts[:keepalive] || @default_keepalive
    strategy = opts[:strategy] || @default_strategy

    reconnect = case module.__info__(:attributes)[:reconnect] do
      [nil] -> opts[:reconnect] || @default_reconnect
      [mod_reconnect] -> opts[:reconnect] || mod_reconnect
    end

    base_options = Keyword.merge(opts, [
      module: module,
      base_packet: struct(base_packet, hmac_key: hmac_key),
      encode_opts: encode_opts,
      reconnect: reconnect,
      strategy: strategy,
      packet_type: strategy.packet_type()])

    with {:ok, socket} <- strategy.connect(server, port, [:binary, active: false]),
         upgraded <- strategy.upgrade!(socket, ssl_opts) do
      Process.send_after(self(), :"$keepalive", keepalive)
      start
      |> module.init()
      |> process_init(base_options ++ [socket: upgraded])
    else
      {:error, :econnrefused} ->
        # send a reconnect message back to the process.
        Process.send_after(self(), :"$reconnect", reconnect)
        start
        |> module.init()
        |> process_init(base_options ++ [socket: nil])
    end
  end

  @impl true
  def handle_call(_, _, state = %{socket: nil}), do: {:noreply, state}
  def handle_call(val, from, state = %{strategy: strategy}) do
    tcp_data = state.base_packet
    |> struct(type: :call, payload: {from, val})
    |> Packet.encode(state.encode_opts)

    strategy.send(state.socket, tcp_data)
    {:noreply, state}
  end

  @impl true
  def handle_cast(_, state = %{socket: nil}), do: {:noreply, state}
  def handle_cast(val, state = %{strategy: strategy}) do
    #instrument data into the packet and convert to binary.
    tcp_data = state.base_packet
    |> struct(type: :cast, payload: val)
    |> Packet.encode(state.encode_opts)

    strategy.send(state.socket, tcp_data)
    {:noreply, state}
  end

  @closed [:tcp_closed, :ssl_closed]

  @impl true
  def handle_info({ptype, socket, data}, state = %{socket: socket, packet_type: ptype})do

    # NB: currently, we're trusting the RPS server to not send us malicious
    # or unverified content.  This may change in the future.

    case Packet.decode(data) do
      {:error, error} ->
        Logger.error(error)
        {:noreply, state}
      {:ok, %Packet{type: :push, payload: payload}} ->
        push_impl(payload, state)
      {:ok, %Packet{type: :reply, payload: {reply, from}}} ->
        GenServer.reply(from, reply)
        {:noreply, state}
      {:ok, %Packet{type: :error, payload: {reply, from}}} ->
        GenServer.reply(from, {:error, reply})
        {:noreply, state}
      {:ok, %Packet{type: :error, payload: payload}} ->
        Logger.error(payload)
        {:noreply, state}
    end
  end
  def handle_info({closed, socket}, state = %{socket: socket}) when closed in @closed do
    {:stop, closed, state}
  end
  def handle_info(:"$reconnect", state = %{socket: nil, strategy: strategy}) do
    case strategy.connect(state.server, state.port, [:binary, active: true]) do
      {:ok, socket} ->
        upgraded = strategy.upgrade!(socket, state.ssl_opts)
        Process.send_after(self(), :"$keepalive", state.keepalive)
        {:noreply, %{state | socket: upgraded}}
      {:error, :econnrefused} ->
        Process.send_after(self(), :"$reconnect", state.reconnect)
        {:noreply, state}
    end
  end
  def handle_info(:"$keepalive", state = %{strategy: strategy}) do
    keepalive_packet = Packet.encode(%Packet{})
    strategy.send(state.socket, keepalive_packet)
    Process.send_after(self(), :"$keepalive", state.keepalive)
    {:noreply, state}
  end
  def handle_info(info, state = %{module: module}) do
    info
    |> module.handle_info(state.data)
    |> process_noreply(state)
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

  @doc """
  Invoked to set up the process.

  Like `GenServer.init/1`, this function is called from inside
  the process immediately after `start_link/3` or `start/3`.

  ### Return codes
  - `{:ok, state}` a succesful startup of your intialization logic and sets the
    internal state of your server to `state`.
  - `{:ok, state, timeout}` the above, plus a :timeout atom will be sent to
    `c:handle_info/2` *if no other messages come by*.
  - `{:ok, state, :hibernate}` successful startup, followed by a hibernation
    event (see `:erlang.hibernate/3`)
  - `{:ok, state, {:continue, term}}` successful startup, and causes a
    continuation to be triggered after the message is handled, sent to
    `c:handle_continue/3`
  - `:ignore` - Drop the gen_server creation request, because for some reason
    it shouldn't have started.
  - `{:stop, reason}` - a failure in creating the gen_server.  Results in
    `{:error, reason}` being propagated as the result of the start_link
  """
  @callback init(init_arg :: term()) ::
    {:ok, state}
    | {:ok, state, timeout() | :hibernate | {:continue, term()}}
    | :ignore
    | {:stop, reason :: any()}
    when state: term

  @doc """
  Invoked to handle `Erps.Server.push/2` messages.

  `push` is the push message sent by a `Erps.Server.push/2` and `state` is the
  current state of the `Erps.Client`.

  ### Return codes
  see return codes for `handle_continue/2`
  """
  @callback handle_push(push :: term, state :: term) ::
    {:noreply, new_state}
    | {:noreply, new_state, timeout() | :hibernate | {:continue, term()}}
    | {:stop, reason :: term, new_state}
  when new_state: term

  @doc """
  Invoked to handle general messages sent to the client process.

  Most useful if the client needs to be attentive to system messages,
  such as nodedown or monitored processes, but also useful for internal
  timeouts.

  ### Return codes
  see return codes for `handle_continue/2`
  """
  @callback handle_info(msg :: :timeout | term(), state :: term()) ::
    {:noreply, new_state}
    | {:noreply, new_state, timeout() | :hibernate | {:continue, term()}}
    | {:stop, reason :: term(), new_state}
    when new_state: term()

  @doc """
  Invoked when an internal callback requests a continuation, using `{:noreply,
  state, {:continue, continuation}}`.

  The continuation is passed as the first argument of this callback.  Most
  useful if `c:init/2` functionality is long-running and needs to be broken
  up into separate parts so that the calling `start_link/2` doesn't block.

  ### Return codes
  - `{:noreply, new_state}` continues the loop with new state `new_state`
  - `{:noreply, new_state, timeout}` causes a :timeout message to be sent to
    `c:handle_info/2` *if no other message comes by*
  - `{:noreply, new_state, :hibernate}`, causes a hibernation event (see
    `:erlang.hibernate/3`)
  - `{:noreply, new_state, {:continue, term}}` causes a continuation to be
    triggered after the message is handled, it will be sent to
    `c:handle_continue/3`
  - `{:stop, reason, new_state}` terminates the loop, passing `new_state`
    to `c:terminate/2`, if it's implemented.
  """

  @callback  handle_continue(continue :: term(), state :: term()) ::
    {:noreply, new_state}
    | {:noreply, new_state, timeout() | :hibernate | {:continue, term()}}
    | {:stop, reason :: term(), new_state}
    when new_state: term()

  @doc """
  Invoked when the client is about to exit.

  This would usually occur due to `handle_push/2` returning a
  `{:stop, reason, new_state}` tuple, but also if the TCP connection
  happens to go down.
  """
  @callback terminate(reason, state :: term) :: term
  when reason: :normal | :shutdown | {:shutdown, term}

  @optional_callbacks handle_continue: 2, handle_info: 2, handle_push: 2, terminate: 2
end
