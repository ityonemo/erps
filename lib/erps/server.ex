defmodule Erps.Server do
  defmacro __using__(_opts) do
    quote do
      @behaviour Erps.Server
    end
  end

  defstruct [:module, :data, :port, :socket]

  @behaviour GenServer

  def start_link(module, param, opts) do
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

  def port(srv), do: GenServer.call(srv, :"$port")
  defp port_impl(state) do
    {:reply, :inet.port(state.socket), state}
  end

  def call(srv, content, timeout \\ 5000), do: GenServer.call(srv, {:"$srv", content}, timeout)

  # router
  def handle_call(:"$port", _from, state), do: port_impl(state)
  def handle_call({:"$srv", content}, from, state = %{module: module}) do
    case module.handle_call(content, from, state.data) do
      {:reply, reply, data} ->
        {:reply, reply, %{state | data: data}}
    end
  end

  @spec handle_info(any, any) :: {:noreply, any}
  def handle_info(:accept, state) do
    :gen_tcp.accept(state.socket, 100)
    Process.send_after(self(), :accept, 0)
    {:noreply, state}
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

  defp process_call(call_result, socket, ref, state) do
    case call_result do
      {:reply, reply, data} ->
        :gen_tcp.send(socket, :erlang.term_to_binary({reply, ref}))
        {:noreply, %{state | data: data}}
    end
  end

  defp process_cast(call_result, state) do
    case call_result do
      {:noreply, data} ->
        {:noreply, %{state | data: data}}
    end
  end
end
