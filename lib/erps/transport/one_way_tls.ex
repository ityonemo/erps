defmodule Erps.Transport.OneWayTls do

  @moduledoc """
  implements a one-way TLS transport strategy.

  this transport is equivalent to a traditional http/grpc transport, where a client
  does not have to be authenticated to a server, but the server must be
  authenticated to the client.

  WARNING: currently, there must exist a high level of trust between the client
  and the server, as certain attack vectors have not been closed yet.  Use at your
  own risk!
  """

  @behaviour Erps.Transport.Api
  alias Erps.Transport.Api

  @impl true
  @spec listen(:inet.port_number, keyword) :: {:ok, :inet.socket} | {:error, any}
  @doc """
  (server) opens a TCP port to listen for incoming connection requests.

  Verifies that the tls options `:cacertfile`, `:certfile`, and `:keyfile` exist
  under the keyword `:tls_opts`, and point to existing files (but not the validity
  of their authority chain or their crytographic signing).

  Callback implementation for `c:Erps.Transport.Api.listen/2`.
  """
  def listen(port, opts) do
    # perform early basic validation of tls options.
    tls_opts = opts[:tls_opts]
    unless tls_opts, do: raise "tls options not provided."
    verify_valid!(tls_opts, :cacertfile)
    verify_valid!(tls_opts, :certfile)
    verify_valid!(tls_opts, :keyfile)
    Api.listen(port, opts)
  end

  defp verify_valid!(opt, key) do
    filepath = opt[key]
    unless filepath, do: raise "#{key} not provided"
    File.exists?(filepath) || raise "#{key} not a valid file"
  end

  @type socket :: Erps.Transport.Api.socket

  @spec accept(socket, timeout) :: {:ok, socket} | {:error, term}
  @doc "Callback implementation for `c:Erps.Transport.Api.accept/2`."
  defdelegate accept(sock, timeout), to: :gen_tcp

  @spec connect(term, :inet.port_number, keyword) :: {:ok, socket} | {:error, term}
  @doc "Callback implementation for `c:Erps.Transport.Api.connect/3`."
  defdelegate connect(host, port, opts), to: :gen_tcp

  @spec recv(socket, non_neg_integer) :: {:ok, binary} | {:error, term}
  @doc "Callback implementation for `c:Erps.Transport.Api.recv/2`, via `:ssl.recv/2`."
  defdelegate recv(sock, length), to: :ssl

  @spec recv(socket, non_neg_integer, timeout) :: {:ok, binary} | {:error, term}
  @doc "Callback implementation for `c:Erps.Transport.Api.recv/3`, via `:ssl.recv/3`."
  defdelegate recv(sock, length, timeout), to: :ssl

  @spec send(socket, iodata) :: :ok | {:error, term}
  @doc "Callback implementation for `c:Erps.Transport.Api.send/2`, via `:ssl.send/2`"
  defdelegate send(sock, content), to: :ssl

  @default_client_tls_opts [verify: :verify_peer, fail_if_no_peer_cert: true]

  @impl true
  @spec upgrade(socket, keyword) :: {:ok, :ssl.socket} | {:error, term}
  @doc """
  (client) responds to a server TLS `handshake/2` request, by upgrading to an encrypted connection.
  Verifies the identity of the server CA, and reject if it's not a valid peer.

  Callback implementation for `c:Erps.Transport.Api.upgrade/2`.
  """
  def upgrade(_, nil), do: raise "tls socket not configured"
  def upgrade(socket, tls_opts) do
    {socket_opts, connect_opts} = @default_client_tls_opts
    |> Keyword.merge(tls_opts)
    |> Keyword.split([:active])

    with {:ok, tls_socket} <- :ssl.connect(socket, connect_opts),
         :ok <- :ssl.setopts(tls_socket, socket_opts) do
      {:ok, tls_socket}
    end
  end

  @impl true
  @doc """
  (server) initiates a client `upgrade/2` request, by upgrading to an encrypted connection.
  Performs no authentication of the client.

  Callback implementation for `c:Erps.Transport.Api.handshake/2`.
  """
  @spec handshake(:inet.socket, keyword) :: {:ok, Api.socket} | {:error, any}
  def handshake(socket, tls_opts) do
    with {:ok, tls_socket} <- :ssl.handshake(socket, tls_opts),
         :ok <- :ssl.setopts(tls_socket, active: true) do
      {:ok, tls_socket}
    else
      any ->
        :gen_tcp.close(socket)
        any
    end
  end

  @impl true
  @spec transport_type :: :ssl
  def transport_type, do: :ssl
end
