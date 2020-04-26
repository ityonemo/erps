

defmodule Erps.Transport.Tcp do

  @moduledoc """
  implements a tcp transport strategy.
  """

  @behaviour Erps.Transport.Api
  alias Erps.Transport.Api

  @type socket :: Erps.Transport.Api.socket

  @spec listen(:inet.port_number, keyword) :: {:ok, socket} | {:error, term}
  @doc "Callback implementation for `c:Erps.Transport.Api.listen/2`."
  defdelegate listen(port, opts), to: Api

  @spec accept(socket, timeout) :: {:ok, socket} | {:error, term}
  @doc "Callback implementation for `c:Erps.Transport.Api.accept/2`."
  defdelegate accept(sock, timeout), to: :gen_tcp

  @spec connect(term, :inet.port_number, keyword) :: {:ok, socket} | {:error, term}
  @doc "Callback implementation for `c:Erps.Transport.Api.connect/3`."
  defdelegate connect(host, port, opts), to: :gen_tcp

  @spec recv(socket, non_neg_integer) :: {:ok, binary} | {:error, term}
  @doc "Callback implementation for `c:Erps.Transport.Api.recv/2`, via `:gen_tcp.recv/2`."
  defdelegate recv(sock, length), to: :gen_tcp

  @spec recv(socket, non_neg_integer, timeout) :: {:ok, binary} | {:error, term}
  @doc "Callback implementation for `c:Erps.Transport.Api.recv/3`, via `:gen_tcp.recv/3`."
  defdelegate recv(sock, length, timeout), to: :gen_tcp

  @spec send(socket, iodata) :: :ok | {:error, term}
  @doc "Callback implementation for `c:Erps.Transport.Api.send/2`, via `:gen_tcp.send/2`"
  defdelegate send(sock, content), to: :gen_tcp

  @impl true
  @spec upgrade(socket, keyword) :: {:ok, :inet.socket} | {:error, term}
  @doc """
  upgrades the socket to `active: true`.  Does not upgrade to an authenticated
  or encrypted channel.

  Callback implementation for `c:Erps.Transport.Api.upgrade/2`.
  """
  def upgrade(socket, opts) do
    case :inet.setopts(socket, Keyword.take(opts, [:active])) do
      :ok -> {:ok, socket}
      error -> error
    end
  end

  @impl true
  @spec handshake(:inet.socket, keyword) :: {:ok, Api.socket}
  @doc """
  upgrades the socket to `active: true`.  Does not request the client-side for an
  upgrade to an authenticated or encrypted channel.

  Callback implementation for `c:Erps.Transport.Api.handshake/2`.
  """
  def handshake(socket, opts!) do
    opts! = Keyword.take(opts!, [:active])
    case :inet.setopts(socket, opts!) do
      :ok -> {:ok, socket}
      any -> any
    end
  end

  @impl true
  @spec transport_type :: :tcp
  def transport_type, do: :tcp
end
