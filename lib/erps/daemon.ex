defmodule Erps.Daemon do
  use GenServer

  # defaults the transport to TLS for library users. For internal library
  # testing, this defaults to Tcp.  If you're testing your own erps server,
  # you can override this with the transport argument.

  require Logger

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
      keyfile:         Path.t
    ]
  }

  @gen_server_opts [:debug, :timeout, :hibernate_after, :spawn_opt, :name]

  @spec start(module, term, keyword) :: GenServer.on_start
  def start(server_module, data, options \\ []) do
    # partition into gen_server options and daemon options
    {gen_server_options, daemon_options} = options
    |> Keyword.merge(server_module: server_module, initial_data: data)
    |> Keyword.split(@gen_server_opts)

    GenServer.start(__MODULE__, daemon_options, gen_server_options)
  end

  @spec start_link(module, term, keyword) :: GenServer.on_start
  def start_link(server_module, data, options! \\ []) do
    options! = put_in(options!, [:spawn_opt], [:link | (options![:spawn_opt] || [])])
    start(server_module, data, options!)
  end

  @default_listen_opts [reuseaddr: true]
  @tcp_listen_opts [:buffer, :delay_send, :deliver, :dontroute, :exit_on_close,
  :header, :highmsgq_watermark, :high_watermark, :keepalive, :linger,
  :low_msgq_watermark, :low_watermark, :nodelay, :packet, :packet_size, :priority,
  :recbuf, :reuseaddr, :send_timeout, :send_timeout_close, :show_econnreset,
  :sndbuf, :tos, :tclass, :ttl, :recvtos, :recvtclass, :recvttl, :ipv6_v6only]

  def init(opts) do
    state = struct(__MODULE__, opts)
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
  retrieve the TCP port that the pony express server is bound to.

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

  defp to_server(state, child_sock) do
    server_opts = state
    |> Map.from_struct()
    |> Map.take([:tls_opts, :transport])
    |> Map.put(:socket, child_sock)
    |> Enum.map(&(&1))

    {state.initial_data, server_opts}
  end

  defp do_start_server(
      state = %{server_supervisor: nil, server_module: server},
      child_sock) do

    # unsupervised case.  Not recommended, except for testing purposes.
    {data, server_opts} = to_server(state, child_sock)

    Erps.Server.start_link(server, data, server_opts)
  end
  #defp do_start_server(
  #    state = %{server_supervisor: {supervisor, name}, server_module: server}, child_sock) do
  #  # custom supervisor case.
  #  supervisor.start_child(name,
  #    {server, to_server(state, child_sock)})
  #end
  defp do_start_server(
      state = %{server_supervisor: sup, server_module: server}, child_sock) do
    # default, DynamicSupervisor case
    DynamicSupervisor.start_child(sup, {server, to_server(state, child_sock)})
  end

  #############################################################################
  ## Reentrant function that lets us keep accepting forever.

  def handle_info(:accept, state = %{transport: transport}) do
    with {:ok, child_sock} <- transport.accept(state.socket, state.timeout),
         {:ok, srv_pid} <- do_start_server(state, child_sock) do
      # transfer ownership to the child server.
      :gen_tcp.controlling_process(child_sock, srv_pid)
      # signal to the child server that the ownership has been transferred.
      Erps.Server.allow(srv_pid)
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
