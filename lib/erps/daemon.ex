defmodule Erps.Daemon do
  @moduledoc """
  A Process which sits on a TCP port and listens to inbound connections, handing
  them off to `Erps.Server` modules when an connection arrives.

  The Daemon also manages putting those server processes into supervision trees,
  usually a `DynamicSupervisor`.  Each server will be seeded with a common initial
  data and common options, though they may incur specialization once handed off
  to the `Erps.Server` module's `start_link/2` and `init/1` functions.

  ### Example:

  this invocation will initialize the `Erps.Server` `MyServer` with an empty map,
  supervised by the `DynamicSupervisor` named `ServerSupervisor`.  See `start_link/2`
  for more supervision options.

  ```
  Erps.Daemon.start_link(MyServer, %{}, port: <port_number>, server_supervisor: ServerSupervisor)
  ```

  Typically, you will also want to supervise `Erps.Daemon` itself, in which case you
  should use the following form, passing it into a static `Supervisor`:

  ```
  children = [{Erps.Daemon, {MyServer, %{}, port: <port_number>, server_supervisor: ServerSupervisor}}]
  ```

  You may override the standard child_spec parameters `[:id, :restart, :shutdown]` in the options list of the tuple.
  """

  use Multiverses, with: [GenServer, DynamicSupervisor]
  use GenServer

  require Logger

  # defaults the transport to TLS for library users. For internal library
  # testing, this defaults to Tcp.  If you're testing your own erps server,
  # you can override this with the transport argument.

  if Mix.env in [:dev, :test] do
    @default_transport Transport.Tcp
  else
    @default_transport Transport.Tls
  end

  @enforce_keys [:server_module, :initial_data]

  defstruct @enforce_keys ++ [
    port:              0,
    socket:            nil,
    timeout:           1000,
    transport:         @default_transport,
    server_supervisor: nil,
    tls_opts:          [],
    server_options:    [],
  ]

  @type socket :: :inet.socket | :ssl.socket

  @typedoc false
  @type state :: %__MODULE__{
    server_module:     module,
    initial_data:      term,
    port:              :inet.port_number,
    socket:            nil | socket,
    timeout:           timeout,
    transport:         module,
    server_supervisor: GenServer.server | {module, term} | nil,
    tls_opts: [
      cacertfile:      Path.t,
      certfile:        Path.t,
      keyfile:         Path.t],
    server_options:    keyword,
  }

  def child_spec({server_module, data, options}) do
    default = %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [server_module, data, options]}
    }
    Supervisor.child_spec(default, Keyword.take(options, [:id, :restart, :shutdown]))
  end

  @forward_callers if Application.compile_env(:erps, :use_multiverses), do: [:forward_callers], else: []
  @gen_server_opts [:name, :timeout, :debug, :spawn_opt, :hibernate_after] ++ @forward_callers

  @spec start(module, term, keyword) :: GenServer.on_start
  @doc "see `start_link/2`"
  def start(server_module, data, options \\ []) do
    # partition into gen_server options and daemon options
    gen_server_options = Keyword.take(options, @gen_server_opts)

    server_options = options
    |> Keyword.get(:server_options, [])
    |> Keyword.merge(forward_callers: options[:forward_callers])

    daemon_options = options
    |> Keyword.drop(@gen_server_opts)
    |> Keyword.merge(server_module: server_module, initial_data: data, server_options: server_options)

    GenServer.start(__MODULE__, daemon_options, gen_server_options)
  end

  @spec start_link(module, term, keyword) :: GenServer.on_start
  @doc """
  launches a Erps Daemon, linked to the calling process

  You can pass these general options which will propagate to the `Erps.Server`s.
  You may also want to specify the supervision tree using the `:server_supervisor`
  option as follows:

  - `server_supervisor: pid_or_name` assumes the supervisor is `DynamicSupervisor` (or
    equivalent) and calls `DynamicSupervisor.start_child/2`
  - `server_supervisor: {module, name}` allows you to use a generic module for supervision
    and calls `module.start_child/2` with the server module and the arity-2 parameters for
    the `server_module.start_link/2` function.
  - `forward_callers: true` causes the daemon and its spawned servers to adopt the universe
    of the caller.  see `Multiverses` for details

  other options you may want to override:

  - `:port`, sets the TCP port the daemon will listen on.  Defaults to 0, which
    means that a random port will be selected, and must be retrieved using `port/1`
  - `:transport`, useful for mocking with TCP instead of TLS in tests
  - `:tls_opts`, useful for specifiying TLS parameters shared by all server processes
  """
  def start_link(server_module, data, options! \\ []) do
    options! = put_in(options!, [:spawn_opt], [:link | Keyword.get(options!, :spawn_opt, [])])
    start(server_module, data, options!)
  end

  @default_listen_opts [reuseaddr: true]
  @tcp_listen_opts [:buffer, :delay_send, :deliver, :dontroute, :exit_on_close,
  :header, :highmsgq_watermark, :high_watermark, :keepalive, :linger,
  :low_msgq_watermark, :low_watermark, :nodelay, :packet, :packet_size, :priority,
  :recbuf, :reuseaddr, :send_timeout, :send_timeout_close, :show_econnreset,
  :sndbuf, :tos, :tclass, :ttl, :recvtos, :recvtclass, :recvttl, :ipv6_v6only]

  @doc false
  def init(opts) do
    saved_options = Keyword.drop(opts, Map.keys(__struct__()))
    state = struct(__MODULE__, opts ++ [options: saved_options])
    listen_opts = @default_listen_opts
    |> Keyword.merge(opts)
    |> Keyword.take(@tcp_listen_opts)

    case state.transport.listen(state.port, listen_opts) do
      {:ok, socket} ->
        trigger_accept()
        {:ok, %{state | socket: socket}}
      {:error, what} ->
        {:stop, what}
    end
  end

  #############################################################################
  ## API

  @doc """
  retrieve the TCP port that the erps daemon is bound to.

  Useful for tests - when we want to assign it a port of 0 so that it gets
  "any free port" of the system.
  """
  @spec port(GenServer.server) :: {:ok, :inet.port_number} | {:error, any}
  def port(srv), do: GenServer.call(srv, :port)

  @spec port_impl(state) :: {:reply, any, state}
  defp port_impl(state = %{port: 0}) do
    {:reply, :inet.port(state.socket), state}
  end
  defp port_impl(state) do
    {:reply, {:ok, state.port}, state}
  end

  # internal function (but also available for public use) that gives you
  # visibility into the internals of the pony express daemon.  Results of
  # this function should not be relied upon for forward compatibility.
  @doc false
  @spec info(GenServer.server) :: state
  def info(srv), do: GenServer.call(srv, :info)

  @spec info_impl(state) :: {:reply, state, state}
  defp info_impl(state), do: {:reply, state, state}

  #############################################################################
  ## Server spawning

  defp to_server(state) do
    server_opts = state
    |> Map.from_struct()
    |> Map.take([:tls_opts, :transport])
    |> Enum.map(&(&1))
    |> Keyword.merge(state.server_options)

    {state.initial_data, server_opts}
  end

  defp do_start_server(
      state = %{server_supervisor: nil, server_module: server}) do
    # unsupervised case.  Not recommended, except for testing purposes.
    {data, server_opts} = to_server(state)
    # requires start_link/2
    server.start_link(data, server_opts)
  end
  defp do_start_server(
      state = %{server_supervisor: {supervisor, sup}, server_module: server}) do
    # custom supervisor case.
    supervisor.start_child(sup, {server, to_server(state)})
  end
  defp do_start_server(
      state = %{server_supervisor: sup, server_module: server}) do
    # default, DynamicSupervisor case
    DynamicSupervisor.start_child(sup, {server, to_server(state)})
  end

  #############################################################################
  ## Reentrant function that lets us keep accepting forever.

  def handle_info(:accept, state = %{transport: transport}) do
    with {:ok, child_sock} <- transport.accept(state.socket, state.timeout),
         {:ok, srv_pid} <- do_start_server(state),
         # transfer ownership to the child server.
         :ok <- :gen_tcp.controlling_process(child_sock, srv_pid) do
      # signal to the child server that the ownership has been transferred.
      Erps.Server.allow(srv_pid, child_sock)
    else
      {:error, :timeout} ->
        # this is normal.  Just quit out and enter the accept loop.
        :ok
      {:error, error} ->
        Logger.error("unexpected error connecting #{inspect error}")
    end
    # trigger the next round of accepts.
    trigger_accept()
    {:noreply, state}
  end

  #############################################################################
  ## Router

  def handle_call(:port, _from, state), do: port_impl(state)
  def handle_call(:info, _from, state), do: info_impl(state)

  #############################################################################
  ## Helper functions

  defp trigger_accept do
    Process.send_after(self(), :accept, 0)
  end
end
