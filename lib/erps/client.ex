defmodule Erps.Client do

  @behaviour GenServer

  @zero_version %Version{major: 0, minor: 0, patch: 0, pre: []}

  alias Erps.Packet

  defmacro __using__(opts) do
    version = if opts[:version] do
      Version.parse!(opts[:version])
    else
      @zero_version
    end

    options = Keyword.merge(opts, version: version)

    base_packet = Packet
    |> struct(options)
    |> Macro.escape

    Module.register_attribute(__CALLER__.module, :base_packet, persist: true)
    Module.register_attribute(__CALLER__.module, :encode_opts, persist: true)
    Module.register_attribute(__CALLER__.module, :hmac_key,    persist: true)
    Module.register_attribute(__CALLER__.module, :sign_with,   persist: true)

    encode_opts = Keyword.take(options, [:compressed])

    quote do
      @behaviour   Erps.Client
      @base_packet unquote(base_packet)
      @encode_opts unquote(encode_opts)
      @sign_with   unquote(options[:sign_with])
    end
  end

  defstruct [:module, :socket, :server, :port, :data, :base_packet,
    :encode_opts, :hmac_key, :signature]

  @type hmac_function :: ( -> String.t)
  @type signing_function :: ((content :: binary, key :: binary) -> signature :: binary)

  @typep state :: %__MODULE__{
    module:      module,
    socket:      :gen_tcp.socket,
    server:      :inet.address,
    port:        :inet.port_number,
    data:        term,
    base_packet: Packet.t,
    encode_opts: list,
    hmac_key:    nil | hmac_function,
    signature:   nil | signing_function
  }

  require Logger

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

    case :gen_tcp.connect(server, port, [:binary, active: true]) do
      {:ok, socket} ->
        start
        |> module.init()
        |> process_init([
          module: module,
          socket: socket,
          base_packet: struct(base_packet, hmac_key: hmac_key),
          encode_opts: encode_opts] ++ opts)
    end
  end

  def call(srv, val), do: GenServer.call(srv, val)
  def cast(srv, val), do: GenServer.cast(srv, val)

  @impl true
  def handle_call(val, from, state) do
    tcp_data = state.base_packet
    |> struct(type: :call, payload: {from, val})
    |> Packet.encode(state.encode_opts)

    :gen_tcp.send(state.socket, tcp_data)
    {:noreply, state}
  end

  @impl true
  def handle_cast(val, state) do
    #instrument data into the packet and convert to binary.
    tcp_data = state.base_packet
    |> struct(type: :cast, payload: val)
    |> Packet.encode(state.encode_opts)

    :gen_tcp.send(state.socket, tcp_data)
    {:noreply, state}
  end

  @impl true
  def handle_info({:tcp, socket, data}, state = %{socket: socket}) do
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
  def handle_info({:tcp_closed, socket}, state = %{socket: socket}) do
    {:stop, :tcp_closed, state}
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
