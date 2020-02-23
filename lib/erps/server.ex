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

  def start(module, param, opts) do
    inner_opts = Keyword.take(opts, [:port])
    GenServer.start(__MODULE__, {module, param, inner_opts}, opts)
  end

  def start_link(module, param, opts \\ []) do
    inner_opts = Keyword.take(opts, [:port])
    GenServer.start_link(__MODULE__, {module, param, inner_opts}, opts)
  end

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
  ##

  def call(srv, content, timeout \\ 5000), do: GenServer.call(srv, {:"$srv", content}, timeout)

  #############################################################################
  # router

  def handle_call(:"$port", _from, state), do: port_impl(state)
  def handle_call(:"$connections", _from, state), do: connections_impl(state)
  def handle_call({:"$disconnect", port}, _from, state), do: disconnect_impl(port, state)
  def handle_call({:"$srv", content}, from, state = %{module: module}) do
    case module.handle_call(content, from, state.data) do
      {:reply, reply, data} ->
        {:reply, reply, %{state | data: data}}
    end
  end
  def handle_call(push = {:"$push", _}, _from, state) do
    push_impl(push, state)
  end

  @spec handle_info(any, any) :: {:noreply, any}
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
        |> process_call(socket, from, state)
      {:"$cast", data} ->
        data
        |> module.handle_cast(state.data)
        |> process_cast(state)
    end
  end
  def handle_info({:tcp_closed, port}, state) do
    {:noreply, %{state | connections: Enum.reject(state.connections, &(&1 == port))}}
  end
  def handle_info(val, state) do
    val |> IO.inspect(label: "114")
    {:noreply, state}
  end

  defp process_call(call_result, socket, ref, state) do
    case call_result do
      {:reply, reply, data} ->
        :gen_tcp.send(socket, :erlang.term_to_binary({reply, ref}))
        {:noreply, %{state | data: data}}
      {:reply, reply, data, timeout} ->
        :gen_tcp.send(socket, :erlang.term_to_binary({reply, ref}))
        {:noreply, %{state | data: data}, timeout}
    end
  end

  defp process_cast(call_result, state) do
    case call_result do
      {:noreply, data} ->
        {:noreply, %{state | data: data}}
    end
  end
end
