defmodule Erps.Client do
  @moduledoc """

  Create an Erps client GenServer.

  The best way to think of an Erps client is that it is a GenServer that forwards
  its `call/2` and `cast/2` callbacks to a remote GenServer over a LAN or WAN.
  This callbacks would normally be provided by standard `GenServer.call/2` and
  `GenServer.cast/2` semantics over erlang distribution but sometimes you just
  don't want that (see `Erps`).

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
  - `:identifier` (optional) a binary identifier for your Erps API endpoint.
    Maximum 36 bytes, suggested to be human-readable.  This must match the
    identifier on the server in order for there to be a successful connection.
  - `:safe` (see `:erlang.binary_to_term/2`), for decoding terms.  If
    set to `false`, then allows undefined atoms and lambdas to be passed
    via the protocol.  This should be used with extreme caution, as
    disabling safe mode can be an attack vector. (defaults to `true`)


  ### Example
  ```
  defmodule MyClient do
    use Erps.Client, version: "0.2.4",
                     identifier: "my_api",
                     safe: false

    def start_link(iv) do
      Erps.Client.start_link(__MODULE__, init,
        server: "my_api-server.example.com",
        port: 4747,
        transport: Transport.Tls,
        tls_opts: [...])
    end

    def init(iv), do: {:ok, iv}
  end
  ```

  ## Important Notes

  - Calls are non-blocking for the Erps clients (and can be for the servers,
    if you so implement them).  You may issue multiple, asynchronous calls
    across the network from different processes and they will be routed
    correctly and will only interfere with each other in terms of the
    connection arbitration overhead.
  """

  @behaviour Connection

  @zero_version %Version{major: 0, minor: 0, patch: 0, pre: []}

  if Mix.env in [:dev, :test] do
    @default_transport Transport.Tcp
  else
    @default_transport Application.get_env(:erps, :transport, Transport.Tls)
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
    supervision_opts = Keyword.take(options, [:id, :restart, :shutdown])

    quote do
      def child_spec({data, opts}) do
        default = %{
          id: {opts[:server], opts[:port]},
          start: {__MODULE__, :start_link, [data, opts]}
        }
        Supervisor.child_spec(default, unquote(Macro.escape(supervision_opts)))
      end

      @behaviour   Erps.Client
      @base_packet unquote(base_packet)
      @encode_opts unquote(encode_opts)
      @sign_with   unquote(options[:sign_with])
      @reconnect   unquote(options[:reconnect])

      defoverridable child_spec: 1
    end
  end

  # one minute keepalive interval.
  @default_keepalive 60_000
  @default_reply_ttl 5000

  defstruct [:module, :tcp_socket, :socket, :server, :port, :data,
    :base_packet, :encode_opts, :hmac_key, :signature, :reconnect,
    tls_opts: [], decode_opts: [safe: true],
    keepalive: @default_keepalive,
    transport: @default_transport,
    reply_cache: %{},
    reply_ttl: @default_reply_ttl
  ]

  # these two features are currently disabled, pending investigation
  @typedoc false
  @type hmac_function :: (() -> String.t)
  @typedoc false
  @type signing_function :: ((content :: binary, key :: binary) -> signature :: binary)

  @type reply_ref   :: %{from: GenServer.from, ttl: DateTime.t}
  @type reply_cache :: %{optional(non_neg_integer) => reply_ref}

  @typep state :: %__MODULE__{
    module:         module,
    socket:         nil | Transport.socket,
    server:         :inet.ip_address,
    port:           :inet.port_number,
    data:           term,
    base_packet:    Packet.t,
    encode_opts:    list,
    hmac_key:       nil | hmac_function,
    signature:      nil | signing_function,
    reconnect:      non_neg_integer,
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
    Connection.start(__MODULE__, {module, state, inner_opts}, gen_server_opts)
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
  - `:tls_opts`     options for setting up a TLS connection.
    - `:cacertfile` path to the certificate of your signing authority. (required)
    - `:certfile`   path to the server certificate file. (required for `Transport.Tls`)
    - `:keyfile`    path to the signing key. (required for `Transport.Tls`)
    - `:customize_hostname_check` it's very likely that you might get tls failures if
      you are relying on the OTP builtin hostname checks.  This OTP ssl feature
      lets you override it for something custom.  See `:ssl.client_option/0`
  - `:reply_ttl`    the maximum amount of time that client should wait for `call`
    replies.  Units in ms, defaults to `5000`.

  see `GenServer.start_link/3` for a description of further options.
  """
  def start_link(module, state, opts) do
    {gen_server_opts, inner_opts} = Keyword.split(opts, @gen_server_opts)
    Connection.start_link(__MODULE__, {module, state, inner_opts}, gen_server_opts)
  end

  @default_options [
    keepalive: @default_keepalive,
    reconnect: @default_reconnect,
    tls_opts: []]

  @impl true
  def init({module, data, opts}) do
    instance_options = get_instance_options(opts)

    module_options = get_module_options(module)

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
    |> Keyword.merge(module: module, server: server)

    data
    |> module.init()
    |> process_init(state_params)
  end

  defp get_instance_options(opts) do
    basic_options = Keyword.take(opts, [:tls_opts,
      :safe, :transport, :reconnect])
    transport = opts[:transport] || @default_transport

    adjusted_options = basic_options ++ [transport: transport]

    Keyword.merge(opts, adjusted_options)
  end

  defp get_module_options(module) do
    attributes = module.__info__(:attributes)
    [base_packet] = attributes[:base_packet]
    encode_options = attributes[:encode_opts]
    [base_packet: base_packet, encode_opts: encode_options]
  end

  #############################################################################
  ## Connection Boilerplate

  @impl true
  def connect(_, state = %{transport: transport}) do
    with {:ok, socket} <- transport.connect(state.server, state.port),
         {:ok, upgraded} <- transport.upgrade(socket, tls_opts: state.tls_opts) do
      # start up the repetitive loops
      keepalive_loop(state)
      recv_loop()
      {:ok, %{state | tcp_socket: socket, socket: upgraded}}
    else
      {:error, :econnrefused} ->
        {:backoff, state.reconnect, state}
      {:error, msg} ->
        {:stop, msg, state}
    end
  end

  @impl true
  def disconnect(_, state) do
    :gen_tcp.close(state.tcp_socket)
    {:noconnect, state}
  end

  #############################################################################
  ## API

  @spec socket(GenServer.server) :: Transport.socket
  @doc """
  returns the current socket in use by the server.

  This may be a TCP socket or an SSL socket, or another interface
  depending on what transport strategy you're using.
  """
  def socket(server), do: GenServer.call(server, :"$socket")

  @spec connect(GenServer.server) :: :ok
  @doc """
  triggers a connection.

  Only use this function after using `disconnect/1`
  """
  def connect(server), do: GenServer.call(server, :"connect")

  @spec disconnect(GenServer.server) :: :ok
  @doc """
  triggers a disconnection.

  Useful to silence persistent Erps clients during maintenance phases.
  Note: this might cause upstream errors as consumers of the Erps service
  will emit errors on calls and casts.
  """
  def disconnect(server), do: GenServer.call(server, :"$disconnect")

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
  def handle_call(:"$socket", _, state) do
    {:reply, state.socket, state}
  end
  def handle_call(:"$connect", _, state) do
    {:connect, :later, :ok, state}
  end
  def handle_call(:"$disconnect", _, state) do
    {:disconnect, :later, :ok, state}
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

  @closed [:tcp_closed, :ssl_closed, :closed, :enotconn]

  @impl true
  @spec handle_info(info :: term, state) :: noreply_response
  def handle_info(:recv, state = %{transport: transport, socket: socket}) do
    recv_loop()
    case Packet.get_data(transport, socket, state.decode_opts)  do
      {:error, :timeout} ->
        {:noreply, state}
      {:error, closed} when closed in @closed ->
        {:stop, :disconnected, state}
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
  def handle_info(:"$keepalive", state = %{transport: transport}) do
    keepalive_packet = Packet.encode(%Packet{})
    transport.send(state.socket, keepalive_packet)
    keepalive_loop(state)
    {:noreply, do_check_expired_calls(state)}
  end
  def handle_info({closed, _}, state) when closed in @closed do
    {:stop, :disconnected, state}
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
  @spec terminate(reason, state) :: term
    when reason: :normal | :shutdown | {:shutdown, term}
  def terminate(reason!, state = %{module: module}) do
    if function_exported?(module, :terminate, 2) do
      module.terminate(reason!, state.data)
    end
  end

  #############################################################################
  ## convenience functions

  @recv_timeout 100

  defp recv_loop do
    Process.send_after(self(), :recv, @recv_timeout)
  end

  defp keepalive_loop(state) do
    Process.send_after(self(), :"$keepalive", state.keepalive)
  end

  #############################################################################
  ## ADAPTERS

  @noops [:infinity, :hibernate]

  defp process_init(init_resp, parameters) do
    case init_resp do
      {:ok, data} ->
        {:connect, :init, struct(__MODULE__, [data: data] ++ parameters)}
      {:ok, data, noop} when noop in @noops ->
        {:connect, :init, struct(__MODULE__, [data: data] ++ parameters)}
      {:ok, data, timeout} when is_integer(timeout) ->
        {:backoff, timeout, struct(__MODULE__, [data: data] ++ parameters), timeout}
      {:ok, _, {:continue, _}} ->
        raise ArgumentError, message: "continuations are not supported"
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

  @doc false
  defdelegate code_change(a, b, c), to: Connection

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
  Invoked when the client is about to exit.

  This would usually occur due to `handle_push/2` returning a
  `{:stop, reason, new_state}` tuple, but also if the TCP connection
  happens to go down.
  """
  @callback terminate(reason, state :: term) :: term
  when reason: :normal | :shutdown | {:shutdown, term}

  @optional_callbacks handle_info: 2, handle_push: 2, terminate: 2
end
