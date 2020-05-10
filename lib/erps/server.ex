defmodule Erps.Server do

  @moduledoc """
  Create an Erps server GenServer.

  An Erps server is just a GenServer that has its `call/2` and `cast/2` callbacks
  connected to the external network over a transport portocol.

  ## Basic Operation

  Presuming you have set up TLS credentials, you can instantiate a server
  in basically the same way that you would instantiate a GenServer:

  ```
  defmodule ErpsServer do
    use Erps.Server

    @port <...>

    def start_link(data, opts) do
      Erps.Server.start_link(__MODULE__, data, opts)
    end

    @impl true
    def init(init_state), do: {:ok, init_state}

    def handle_call(:some_remote_call, state) do
      {:reply, :some_remote_response, state}
    end
  end
  ```

  ** NB ** you *must* implement a `start_link/2` in order to be properly
  launched by `Erps.Daemon`.

  Now you may either access these values as a normal, local
  `GenServer`, or access them via `Erps.Client`.  The `Erps.Server` module
  will not know the difference between a local or a remote call.

  ```
  {:ok, server} = ErpsServer.start_link()
  GenServer.call(server, :some_remote_call) #==> :some_remote_response

  {:ok, client} = ErpsClient.start_link()
  GenServer.call(client, :some_remote_call) #==> :some_remote_response
  ```

  ## Module Options

  - `:identifier` a binary identifier for your Erps API endpoint.  Maximum 12
    bytes, suggested to be human-readable.
  - `:versions` client semvers which are accepted.  See the "requirements"
    section in `Version`.
  - `:safe` (see `:erlang.binary_to_term/2`), for decoding terms.  If
    set to `false`, then allows undefined atoms and lambdas to be passed
    via the protocol.  This should be used with extreme caution, as
    disabling safe mode can be an attack vector. (defaults to `true`)
  - `:transport` - set the transport module, which must implement
    `Transport` behaviour.  If you set it to `false`, the
    Erps server will use `Erps.Transport.None` and act similarly to a
    `GenServer` (with some overhead).

  ### Example

  ```
  defmodule MyServer do
    use Erps.Server, versions: "~> 0.2.4",
                     identifier: "my_api",
                     safe: false

    def start_link(iv) do
      Erps.Server.start_link(__MODULE__, init,
        port: ,
        tls_opts: [...])
    end

    def init(iv), do: {:ok, iv}
  end
  ```

  ### Magical features

  The following functions are hoisted to your server module
  so that you can call them in your code with clarity and less
  boilerplate:

  - `push/2`
  - `disconnect/1`

  """

  #############################################################################
  ## module using statement

  defmacro __using__(opts) do
    decode_opts = opts
    |> Keyword.take([:identifier, :versions, :safe, :timeout])

    verification = opts[:verification]

    Module.register_attribute(__CALLER__.module, :decode_opts, persist: true)
    Module.register_attribute(__CALLER__.module, :verification, persist: true)

    if opts[:identifier] && :erlang.size(opts[:identifier]) >= 12 do
      raise CompileError,
        file: __CALLER__.file,
        line: __CALLER__.line,
        description: "identifier size too large"
    end

    supervision_opts = Keyword.take(opts, [:id, :restart, :shutdown])

    quote do
      @behaviour Erps.Server

      # define a set of "magic functions".
      defdelegate push(srv, push), to: Erps.Server
      defdelegate disconnect(srv), to: Erps.Server

      # define a default child_spec, which is overrideable.

      def child_spec({state, options}) do
        default = %{
          id: options[:socket],
          start: {__MODULE__, :start_link, [state, options]},
          restart: :temporary
        }
        Supervisor.child_spec(default, unquote(Macro.escape(supervision_opts)))
      end

      defoverridable child_spec: 1

      @decode_opts unquote(decode_opts)
      @verification unquote(verification)
    end
  end

  #############################################################################

  alias Erps.Packet

  @enforce_keys [:module, :data, :socket, :transport]

  defstruct @enforce_keys ++ [:tcp_socket, decode_opts: [], tls_opts: []]

  @typep state :: %__MODULE__{
    module:      module,
    data:        term,
    socket:      Transport.socket,
    tcp_socket:  :inet.socket,  #keeps the legacy socket around after upgrade.
    transport:   module,
    decode_opts: keyword,
    tls_opts:    keyword
  }

  @behaviour GenServer

  alias Erps.Packet

  @gen_server_opts [:name, :timeout, :debug, :spawn_opt, :hibernate_after]

  @doc """
  starts a server GenServer, not linked to the caller. Most useful for tests.

  see `start_link/3` for a description of avaliable options.
  """
  @spec start(module, term, keyword) :: GenServer.on_start
  def start(module, param, opts \\ []) do
    {gen_server_opts, inner_opts} = Keyword.split(opts, @gen_server_opts)
    GenServer.start(__MODULE__, {module, param, inner_opts}, gen_server_opts)
  end

  @doc """
  starts a server GenServer, linked to the caller.

  ### options

  - `:transport` transport module (see `Transport.Api`)
  - `:tls_opts` options for TLS authorization and encryption.  Should include:
    - `:cacertfile` path to the certificate of your signing authority.
    - `:certfile`   path to the server certificate file.
    - `:keyfile`    path to the signing key.
    - `:customize_hostname_check` see below.

  ### customize_hostname_check

  Erlang/OTP doesn't provide a simple mechanism for a server in a two way ssl
  connection to verify the identity of the client (which you may want in certain
  situations where you own both ends of the connection but not the intermediate
  transport layer).  See `Transport.Tls.handshake/2` and
  `:public_key.pkix_verify_hostname/3` for more details.

  see `GenServer.start_link/3` for a description of further options.
  """
  @spec start_link(module, term, keyword) :: GenServer.on_start
  def start_link(module, param, options! \\ []) do
    options! = put_in(options!, [:spawn_opt], [:link | (options![:spawn_opt] || [])])
    start(module, param, options!)
  end

  @impl true
  @doc false
  def init({module, data, options}) do
    data
    |> module.init
    |> process_init([module: module] ++
      options ++ module.__info__(:attributes))
  end

  ##############################################################################
  ### API

  # convenience type that lets us annotate internal call reply types sane.
  @typep reply(type) :: {:reply, type, state}

  @type server :: GenServer.server

  @doc false
  # PRIVATE API.  Informs the server that ownership of the socket has been
  # passed to it.
  @spec allow(server, :inet.socket) :: :ok
  def allow(server, child_sock), do: GenServer.call(server, {:"$allow", child_sock})

  @spec allow_impl(:inet.socket, GenServer.from, state) :: {:reply, :ok, state}
  defp allow_impl(tcp_socket, _from, state = %{transport: transport}) do
    # perform ssl handshake, upgrade to TLS.
    # next, wait for the subscription signal and set up the phoenix
    # pubsub subscriptions.
    case transport.handshake(tcp_socket, tls_opts: state.tls_opts) do
      {:ok, socket} ->
        recv_loop()
        {:reply, :ok,
          %{state | socket: socket, tcp_socket: tcp_socket}}
      error = {:error, msg} -> {:stop, msg, error, state}
      error -> {:stop, :error, error, state}
    end
  end

  @closed [:tcp_closed, :ssl_closed, :closed, :enotconn]

  # performs the socket receive loop.
  defp recv_impl(state = %{socket: socket, module: module}) do
    case Packet.get_data(state.transport, socket, state.decode_opts) do
      {:ok, %Packet{type: :keepalive}} ->
        recv_loop()
        {:noreply, state}
      {:ok, %Packet{type: :call, payload: {from, data}}} ->
        remote_from = {self(), {:"$remote_reply", socket, from}}
        recv_loop()
        data
        |> module.handle_call(remote_from, state.data)
        |> process_call(remote_from, state)
      {:ok, %Packet{type: :cast, payload: data}} ->
        recv_loop()
        data
        |> module.handle_cast(state.data)
        |> process_noreply(state)
      {:error, :timeout} ->
        recv_loop()
        {:noreply, state}
      {:error, closed} when closed in @closed ->
        {:stop, :disconnected, state}
      {:error, error} when is_binary(error) ->
        tcp_data = Packet.encode(%Packet{
          type: :error,
          payload: error
        })
        state.transport.send(socket, tcp_data)
        {:noreply, state}
      {:error, error} ->
        {:stop, error, state}
    end
  end

  @doc """
  pushes a message to all connected clients.  Causes client `c:Erps.Client.handle_push/2`
  callbacks to be triggered.
  """
  @spec push(server, push::term) :: :ok
  def push(srv, push), do: GenServer.call(srv, {:"$push", push})

  @spec push_impl(push :: term, state) :: reply(:ok)
  defp push_impl(push, state = %{transport: transport}) do
    tcp_data = Packet.encode(%Packet{
      type: :push,
      payload: push
    })
    transport.send(state.socket, tcp_data)
    {:reply, :ok, state}
  end

  @doc """
  disconnects the server, causing it to close.
  """
  @spec disconnect(server) :: :ok
  def disconnect(server), do: GenServer.cast(server, :"$disconnect")

  defp disconnect_impl(state) do
    :gen_tcp.close(state.tcp_socket)
    {:stop, :normal, state}
  end

  #############################################################################
  ## GenServer wrappers

  @doc """
  sends a reply to either a local process or a remotely connected client.

  The Erps Server holds connection information, so you must supply the Erps
  Server pid; though you may use the arity-2 form if you call from within
  the action loop of the Erps Server itself, in which case it acts like
  `GenServer.reply/2`

  naturally takes the `from` value passed in to the second parameter of
  `c:handle_call/3`.
  """
  @spec reply(GenServer.from, term) :: :ok
  def reply(from, reply), do: GenServer.reply(from, reply)

  @spec do_reply(from, term, state) :: :ok
  defp do_reply({pid, {:"$remote_reply", socket, from}}, reply, %{transport: transport})
      when pid == self() do
    tcp_data = Packet.encode(%Packet{type: :reply, payload: {reply, from}})
    transport.send(socket, tcp_data)
  end
  defp do_reply(local_client, reply, _state) do
    GenServer.reply(local_client, reply)
  end

  #############################################################################
  ## router

  # typespec boilerplate #
  @typep noreply_response ::
  {:noreply, state}
  | {:noreply, state, timeout | :hibernate | {:continue, term}}
  | {:stop, reason :: term, state}
  @typep reply_response ::
  {:reply, reply :: term, state}
  | {:reply, reply :: term, state, timeout | :hibernate | {:continue, term}}
  | noreply_response
  # typespec boilerplate #

  @impl true
  @spec handle_call(call :: term, from, state) :: reply_response
  def handle_call({:"$allow", tcp_socket}, from, state) do
    allow_impl(tcp_socket, from, state)
  end
  def handle_call({:"$push", push}, _from, state) do
    push_impl(push, state)
  end
  def handle_call(call, from, state = %{module: module}) do
    call
    |> module.handle_call(from, state.data)
    |> process_call(from, state)
  end

  @impl true
  @spec handle_cast(cast :: term, state) :: noreply_response
  def handle_cast(:"$disconnect", state) do
    disconnect_impl(state)
  end
  def handle_cast(cast, state = %{module: module}) do
    cast
    |> module.handle_cast(state.data)
    |> process_noreply(state)
  end

  @impl true
  def handle_info(:"$recv", state) do
    recv_impl(state)
  end
  def handle_info({from = {:"$remote_reply", _sock, _id}, reply}, state) do
    do_reply({self(), from}, reply, state)
    {:noreply, state}
  end
  def handle_info(info_term, state = %{module: module}) do
    info_term
    |> module.handle_info(state.data)
    |> process_noreply(state)
  end

  @impl true
  @spec handle_continue(continue :: term, state) :: noreply_response
  def handle_continue(continue_term, state = %{module: module}) do
    continue_term
    |> module.handle_continue(state.data)
    |> process_noreply(state)
  end

  @impl true
  @spec terminate(reason, state) :: any
  when reason: :normal | :shutdown | {:shutdown, term}
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

  @spec process_call(term, from, state) :: reply_response
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

  @spec process_noreply(term, state) :: noreply_response
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

  defp recv_loop do
    Process.send_after(self(), :"$recv", 0)
  end

  #############################################################################
  ## BEHAVIOUR CALLBACKS

  @typedoc """
  a `from` term that is either a local `from`, compatible with `t:GenServer.from/0`
  or an opaque term that represents a connected remote client.

  This opaque term is completely compatible with the `t:GenServer.from` type.
  In other words, you may pass this term to `Genserver.reply/2` from any process
  and it will correctly route it to the caller whether it be local or remote.
  """
  @opaque from :: GenServer.from |
    {pid, {:"$remote_reply", Transport.Api.socket, non_neg_integer}}

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
  similar to `c:GenServer.handle_call/3`, but handles content from both
  local and remote clients.

  The `from` term might contain a opaque term which represents a return
  address for a remote client, but you may use this term as expected in
  `reply/2`.

  ### Return codes
  - `{:reply, reply, new_state}` replies, then updates the state of the
    Server.
  - `{:reply, reply, new_state, timeout}` replies, then causes a :timeout
    message to be sent to `c:handle_info/2` *if no other message comes by*
  - `{:reply, reply, new_state, :hibernate}` replies, then causes a
    hibernation event (see `:erlang.hibernate/3`)
  - `{:reply, reply, new_state, {:continue, term}}` replies, then causes
    a continuation to be triggered after the message is handled, it will
    be sent to `c:handle_continue/3`
  - and all return codes supported by `c:GenServer.handle_cast/2`
  """
  @callback handle_call(request :: term, from, state :: term) ::
    {:reply, reply, new_state}
    | {:reply, reply, new_state, timeout | :hibernate | {:continue, term}}
    | {:noreply, new_state}
    | {:noreply, new_state, timeout | :hibernate | {:continue, term}}
    | {:stop, reason, reply, new_state}
    | {:stop, reason, new_state}
    when reply: term, new_state: term, reason: term

  @doc """
  similar to `c:GenServer.handle_cast/2`, but handles content from both local
  and remote clients (if the content has been successfully filtered).

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
  @callback handle_cast(request :: term(), state :: term()) ::
    {:noreply, new_state}
    | {:noreply, new_state, timeout() | :hibernate | {:continue, term()}}
    | {:stop, reason :: term, new_state}
    when new_state: term()

  @doc """
  Invoked to handle general messages sent to the client process.

  Most useful if the client needs to be attentive to system messages,
  such as nodedown or monitored processes, but also useful for internal
  timeouts.

  see: `c:GenServer.handle_info/2`.

  ### Return codes
  see return codes for `c:handle_cast/2`
  """
  @callback handle_info(msg :: :timeout | term(), state :: term()) ::
    {:noreply, new_state}
    | {:noreply, new_state, timeout() | :hibernate | {:continue, term()}}
    | {:stop, reason :: term, new_state}
    when new_state: term()

  @doc """
  Invoked when an internal callback requests a continuation, using `{:noreply,
  state, {:continue, continuation}}`, or from `c:init/1` using
  `{:ok, state, {:continue, continuation}}`

  see: `c:GenServer.handle_continue/2`.

  ### Return codes
  see return codes for `c:handle_cast/2`
  """
  @callback  handle_continue(continue :: term(), state :: term()) ::
    {:noreply, new_state}
    | {:noreply, new_state, timeout() | :hibernate | {:continue, term()}}
    | {:stop, reason :: term, new_state}
    when new_state: term()

  @doc """
  see: `c:GenServer.terminate/2`.
  """
  @callback terminate(reason, state :: term) :: term
  when reason: :normal | :shutdown | {:shutdown, term}

  @optional_callbacks handle_call: 3, handle_cast: 2, handle_info: 2, handle_continue: 2,
    terminate: 2
end
