defmodule Erps.Client do
  @moduledoc """

  Create an Erps client GenServer.

  The best way to think of an Erps client is that it is a GenServer that forwards
  its `call/2` and `cast/2` callbacks to a remote GenServer over a LAN or WAN.
  This callbacks would normally be provided by standard `GenServer.call/2` and
  `GenServer.cast/2` semantics over erlang distribution but in some cases you may
  want to issue a remote protocol request over high-latency or unreliable network
  stretches, or in cases where you would like to have an OTP-supervised connection
  orthogonal to standard erlang distribution semantics.

  ## Basic operation

  Presuming you have set up an Erps server GenServer on some host at `@hostname`,
  you can connect the client and the server simply by instantiating the server
  module.

  ### Example

  ```
  defmodule ErpsClient do
    use Erps.Client

    @hostname <...>
    @port <...>

    def start_link, do: Erps.Client.start_link(__MODULE__, :ok,
      server: @hostname, port: @port, tls_opts: [...])

    def init(init_state), do: {:ok, init_state}
  end

  {:ok, client} = ErpsClient.start_link
  GenServer.call(client, :some_remote_call)
  # => :some_remote_response
  ```

  ## Module options
  - `:version` the version of your Erps API messages.  Should be a SemVer string.
    see `Version` for more information.
  - `:identifier` a binary identifier for your Erps API endpoint.  Maximum 12
    bytes, suggested to be human-readable.
  - `:sign_with` defines the cryptographic signing function for your Erps
    client/server pair.  May take one of two forms:
    - `function` (where `function` is an atom) calls the signing function
      `module.function/2` with the unsigned binary as the first parameter, and
      the `hmac_key` (see `start_link/3` options) as the second parameter.
      The `hmac_key` is passed to the function in the event that the client
      has a KV store which should be queried to find the appropriate signing
      key for the requested connection instance.  `module.function/2` should
      emit a 32-byte signature in response.
    - `{external_module, function}` calls `external_module.function/2` in the
      same fashion as above.
  - `:safe` (see `:erlang.binary_to_term/2`), for decoding terms.  If
    set to `false`, then allows undefined atoms and lambdas to be passed
    via the protocol.  This should be used with extreme caution, as
    disabling safe mode can be an attack vector. (defaults to `true`)


  ### Example
  ```
  defmodule MyClient do
    use Erps.Client, version: "0.2.4",
                     identifier: "my_api",
                     sign_with: :signing,
                     safe: false

    def signing(binary, hmac_key) do
      :crypto.mac(:hmac, :sha256, SecretProvider.secret_for(hmac_key), binary)
    end

    def start_link(iv) do
      Erps.Client.start_link(__MODULE__, init,
        hmac_key: "ABCDEFGHIJKLMNOP",
        server: "my_api-server.example.com",
        port: 4747,
        transport: Erps.Transport.Tls,
        tls_opts: [...])
    end

    def init(iv), do: {:ok, iv}
  end
  ```
  """

  @behaviour GenServer

  @zero_version %Version{major: 0, minor: 0, patch: 0, pre: []}

  if Mix.env in [:dev, :test] do
    @default_transport Erps.Transport.Tcp
  else
    @default_transport Application.get_env(:erps, :transport, Erps.Transport.Tls)
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
    :encode_opts, :hmac_key, :signature, :reconnect, :transport_type,
    tls_opts: [],
    decode_opts: [safe: true],
    keepalive: @default_keepalive,
    transport: @default_transport,
    reply_cache: %{},
    reply_ttl: 5000
  ]

  @type hmac_function :: (() -> String.t)
  @type signing_function :: ((content :: binary, key :: binary) -> signature :: binary)

  @type reply_ref   :: %{from: GenServer.from, ttl: DateTime.t}
  @type reply_cache :: %{optional(non_neg_integer) => reply_ref}

  @typep state :: %__MODULE__{
    module:         module,
    socket:         nil | Erps.socket,
    server:         :inet.ip_address,
    port:           :inet.port_number,
    data:           term,
    base_packet:    Packet.t,
    encode_opts:    list,
    hmac_key:       nil | hmac_function,
    signature:      nil | signing_function,
    reconnect:      non_neg_integer,
    transport_type: :tcp | :ssl,
    tls_opts:       keyword,
    decode_opts:    keyword,
    keepalive:      timeout,
    transport:      module,
    reply_cache:    reply_cache,
    reply_ttl:      non_neg_integer
  }

  require Logger

  @gen_server_opts [:name, :timeout, :debug, :spawn_opt, :hibernate_after]

  @doc """
  starts a client GenServer, not linked to the caller. Most useful for tests.

  see `start_link/3` for a description of avaliable options.
  """
  def start(module, state, opts) do
    {gen_server_opts, inner_opts} = Keyword.split(opts, @gen_server_opts)
    GenServer.start(__MODULE__, {module, state, inner_opts}, gen_server_opts)
  end

  @doc """
  starts a client GenServer, linked to the caller.

  Will attempt to contact the server over the specified transport strategy.  If the
  connection fails, the client will be placed in an invalid state until connection
  succeeds, with a reconnect interval specified in the module options.

  ### options

  - `:server`       IP address of the target server (required)
  - `:port`         IP port of the target server (required)
  - `:transport`    module for communication transport strategy
  - `:keepalive`    time interval for sending a TCP/IP keepalive token.
  - `:hmac_key`     one of two options:
    - `function/0`  a zero-arity function which can be used to fetch the key at runtime
    - `binary`      a directly instrumented value (this could be fetched at vm startup time
      and pulled from `System.get_env/1` or `Application.get_env/2`)
  - `:tls_opts`     options for setting up a TLS connection.
    - `:cacertfile` path to the certificate of your signing authority. (required)
    - `:certfile`   path to the server certificate file. (required for `Erps.Transport.Tls`)
    - `:keyfile`    path to the signing key. (required for `Erps.Transport.Tls`)
  - `:reply_ttl`    the maximum amount of time that client should wait for `call`
    replies.  Units in ms, defaults to `5000`.

  see `GenServer.start_link/3` for a description of further options.
  """
  def start_link(module, state, opts) do
    {gen_server_opts, inner_opts} = Keyword.split(opts, @gen_server_opts)
    GenServer.start_link(__MODULE__, {module, state, inner_opts}, gen_server_opts)
  end

  @default_options [
    keepalive: @default_keepalive,
    reconnect: @default_reconnect]

  @impl true
  def init({module, start, opts}) do
    instance_options = get_instance_options(opts)
    hmac_key = instance_options[:hmac_key]
    transport = instance_options[:transport]

    module_options = get_module_options(module, hmac_key)

    port = opts[:port]
    server = case opts[:server] do
      dns_name when is_binary(dns_name) ->
        String.to_charlist(dns_name)
      dns_charlist when is_list(dns_charlist) ->
        dns_charlist
      ip_addr when is_tuple(ip_addr) ->
        ip_addr
    end

    state_params = @default_options
    |> Keyword.merge(module_options)
    |> Keyword.merge(instance_options)
    |> Keyword.merge(module: module)

    with {:ok, socket} <- transport.connect(server, port, [:binary, active: false]),
         upgraded <- transport.upgrade!(socket, state_params[:tls_opts]) do
      Process.send_after(self(), :"$keepalive", state_params[:keepalive])
      start
      |> module.init()
      |> process_init(state_params ++ [socket: upgraded])
    else
      {:error, :econnrefused} ->
        # send a reconnect message back to the process.
        Process.send_after(self(), :"$reconnect", state_params[:reconnect])
        start
        |> module.init()
        |> process_init(state_params ++ [socket: nil])
    end
  end

  defp get_instance_options(opts) do
    hmac_key_option = case opts[:hmac_key] do
      function when is_function(function, 0) ->
        [hmac_key: function.()]
      binary when is_binary(binary) -> [hmac_key: binary]
      _ -> []
    end

    basic_options = Keyword.take(opts, [:tls_opts,
      :safe, :transport, :reconnect])
    transport = opts[:transport] || @default_transport

    adjusted_options = hmac_key_option ++ basic_options ++
    [transport: transport,
     transport_type: transport.transport_type()]

    Keyword.merge(opts, adjusted_options)
  end

  defp get_module_options(module, hmac_key) do
    attributes = module.__info__(:attributes)
    [base_packet] = attributes[:base_packet]

    encode_options = attributes[:encode_opts] ++
    case attributes[:sign_with] do
      [nil] -> []
      [fun] when is_atom(fun) ->
        verify_signability!(module, fun, hmac_key)
        [sign_with: &apply(module, fun, [&1, hmac_key])]
      [{mod, fun}] ->
        verify_signability!(mod, fun, hmac_key)
        [sign_with: &apply(mod, fun, [&1, hmac_key])]
    end

    reconnect_option = case module.__info__(:attributes)[:reconnect] do
      [nil] -> []
      [mod_reconnect] -> [reconnect: mod_reconnect]
    end

    [base_packet: struct(base_packet, hmac_key: hmac_key),
     encode_opts: encode_options]
    ++ reconnect_option
  end

  defp verify_signability!(module, function, hmac_key) do
    function_exported?(module, function, 2) ||
      raise "#{module}.#{function}/2 not exported; client signing impossible"
    hmac_key ||
      raise "hmac key not provided, client signing impossible."
  end

  #############################################################################
  ## API

  @spec connected?(GenServer.server) :: boolean
  @doc """
  returns `true` if the connection is active
  """
  def connected?(server), do: GenServer.call(server, :"$connected?")

  #############################################################################
  ## ROUTER

  @typep noreply_response ::
  {:noreply, state}
  | {:noreply, state, timeout | :hibernate | {:continue, term}}
  | {:stop, reason :: term, state}

  @typep reply_response ::
  {:reply, reply :: term, state}
  | {:reply, reply :: term, state, timeout | :hibernate | {:continue, term}}
  | noreply_response

  @impl true
  @spec handle_call(call :: term, GenServer.from, state) :: reply_response
  def handle_call(:"$connected?", _, state) do
    {:reply, not is_nil(state.socket), state}
  end
  def handle_call(_, _, %{socket: nil}) do
    raise "call attempted when the client is not connected"
  end
  def handle_call(call, from, state = %{transport: transport}) do
    ref = :erlang.phash2(from)

    tcp_data = state.base_packet
    |> struct(type: :call, payload: {ref, call})
    |> Packet.encode(state.encode_opts)

    transport.send(state.socket, tcp_data)
    # build out the reply cache
    expiry = DateTime.add(DateTime.utc_now(), state.reply_ttl)
    new_reply_cache =
      Map.put(state.reply_cache, ref, %{from: from, ttl: expiry})

    {:noreply, %{state | reply_cache: new_reply_cache}}
  end

  defp handle_call_response(reply, from, state = %{reply_cache: reply_cache}) do
    if is_map_key(reply_cache, from) do
      GenServer.reply(reply_cache[from].from, reply)
      {:noreply, %{state | reply_cache: Map.delete(reply_cache, from)}}
    else
      {:noreply, state}
    end
  end

  defp do_check_expired_calls(state = %{reply_cache: reply_cache}) do
    new_cache = reply_cache
    |> Enum.filter(fn {_, %{ttl: ttl}} ->
      DateTime.compare(DateTime.utc_now(), ttl) == :lt
    end)
    |> Enum.into(%{})
    %{state | reply_cache: new_cache}
  end

  @impl true
  @spec handle_cast(cast :: term, state) :: noreply_response
  def handle_cast(_, state = %{socket: nil}), do: {:noreply, state}
  def handle_cast(cast, state = %{transport: transport}) do
    #instrument data into the packet and convert to binary.
    tcp_data = state.base_packet
    |> struct(type: :cast, payload: cast)
    |> Packet.encode(state.encode_opts)

    transport.send(state.socket, tcp_data)
    {:noreply, state}
  end

  @closed [:tcp_closed, :ssl_closed]

  @impl true
  @spec handle_info(info :: term, state) :: noreply_response
  def handle_info({ttype, socket, data}, state = %{socket: socket, transport_type: ttype})do
    case Packet.decode(data, state.decode_opts) do
      {:error, error} ->
        Logger.error("error decoding response packet: #{inspect error}")
        {:noreply, state}
      {:ok, %Packet{type: :push, payload: payload}} ->
        push_impl(payload, state)
      {:ok, %Packet{type: :reply, payload: {reply, from}}} ->
        handle_call_response(reply, from, state)
      {:ok, %Packet{type: :error, payload: {reply, from}}} ->
        handle_call_response({:error, reply}, from, state)
      {:ok, %Packet{type: :error, payload: payload}} ->
        Logger.error("error response from server: #{inspect payload}")
        {:noreply, state}
    end
  end
  def handle_info({closed, socket}, state = %{socket: socket}) when closed in @closed do
    {:stop, closed, state}
  end
  def handle_info(:"$reconnect", state = %{socket: nil, transport: transport}) do
    case transport.connect(state.server, state.port, [:binary, active: true]) do
      {:ok, socket} ->
        upgraded = transport.upgrade!(socket, state.tls_opts)
        Process.send_after(self(), :"$keepalive", state.keepalive)
        {:noreply, %{state | socket: upgraded}}
      {:error, :econnrefused} ->
        Process.send_after(self(), :"$reconnect", state.reconnect)
        {:noreply, state}
    end
  end
  def handle_info(:"$keepalive", state = %{transport: transport}) do
    keepalive_packet = Packet.encode(%Packet{})
    transport.send(state.socket, keepalive_packet)
    Process.send_after(self(), :"$keepalive", state.keepalive)
    {:noreply, do_check_expired_calls(state)}
  end
  def handle_info(info, state = %{module: module}) do
    info
    |> module.handle_info(state.data)
    |> process_noreply(state)
  end

  @spec push_impl(push :: term, state) :: noreply_response
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
  @spec handle_continue(continue :: term, state) :: noreply_response
  def handle_continue(continuation, state = %{module: module}) do
    continuation
    |> module.handle_continue(state.data)
    |> process_noreply(state)
  end

  @impl true
  @spec terminate(reason, state) :: term
    when reason: :normal | :shutdown | {:shutdown, term}
  def terminate(reason, state = %{module: module}) do
    if function_exported?(module, :terminate, 2) do
      module.terminate(reason, state.data)
    end
  end

  #############################################################################
  ## ADAPTERS

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
  see return codes for `c:handle_continue/2`
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

  see: `c:GenServer.handle_info/2`.

  ### Return codes
  see return codes for `c:handle_continue/2`
  """
  @callback handle_info(msg :: :timeout | term(), state :: term()) ::
    {:noreply, new_state}
    | {:noreply, new_state, timeout() | :hibernate | {:continue, term()}}
    | {:stop, reason :: term(), new_state}
    when new_state: term()

  @doc """
  Invoked when an internal callback requests a continuation, using `{:noreply,
  state, {:continue, continuation}}`, or from `c:init/1` using
  `{:ok, state, {:continue, continuation}}`

  The continuation is passed as the first argument of this callback.  Most
  useful if `c:init/1` functionality is long-running and needs to be broken
  up into separate parts so that the calling `start_link/3` doesn't block.

  see: `c:GenServer.handle_continue/2`.

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
