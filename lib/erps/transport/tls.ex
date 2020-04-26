
defmodule Erps.Transport.Tls do

  @moduledoc """
  implements a two-way TLS transport strategy.

  this transport is useful when you have trusted clients and servers that are
  authenticated against each other and must have an encrypted channel over
  WAN.

  extra options:
  - `:client_verify_fun` see: `Erps.Server`
  """

  @behaviour Erps.Transport.Api
  alias Erps.Transport.Api

  @type socket :: Erps.Transport.Api.socket

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

  @spec accept(socket, timeout) :: {:ok, socket} | {:error, term}
  @doc "Callback implementation for `c:Erps.Transport.Api.accept/2`."
  defdelegate accept(sock, timeout), to: :gen_tcp

  @spec connect(term, :inet.port_number, keyword) :: {:ok, socket} | {:error, term}
  @doc "Callback implementation for `c:Erps.Transport.Api.connect/3`."
  defdelegate connect(host, port, opts), to: :gen_tcp

  @spec send(socket, iodata) :: :ok | {:error, term}
  @doc "Callback implementation for `c:Erps.Transport.Api.send/2`, via `:ssl.send/2`."
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

  @spec recv(socket, non_neg_integer) :: {:ok, binary} | {:error, term}
  @doc "Callback implementation for `c:Erps.Transport.Api.recv/2`, via `:ssl.recv/2`."
  defdelegate recv(sock, length), to: :ssl

  @spec recv(socket, non_neg_integer, timeout) :: {:ok, binary} | {:error, term}
  @doc "Callback implementation for `c:Erps.Transport.Api.recv/3`, via `:ssl.recv/3`."
  defdelegate recv(sock, length, timeout), to: :ssl

  @impl true
  @spec handshake(:inet.socket, keyword) :: {:ok, Api.socket} | {:error, any}
  @doc """
  (server) a specialized function that generates a match function option used to
  verify that the incoming client is bound to a single ip address.
  """
  def handshake(socket, tls_opts!) do
    # instrument in a series of default tls options into the handshake.
    tls_opts! = Keyword.merge([
      client_verify_fun: &no_verification/2,
      verify: :verify_peer,
      fail_if_no_peer_cert: true,
    ], tls_opts!)

    after_opts = Keyword.take(tls_opts!, [:active])

    with {:ok, tls_socket} <- :ssl.handshake(socket, tls_opts!, 200),
         :ok <- :ssl.setopts(tls_socket, after_opts),
         {:ok, raw_certificate} <- :ssl.peercert(tls_socket) do

      tls_opts![:client_verify_fun].(socket, raw_certificate)

    else
      any ->
        :gen_tcp.close(socket)
        any
    end
  end

  @impl true
  @spec transport_type :: :ssl
  def transport_type, do: :ssl

  defp no_verification(socket, _raw_cert) do
    {:ok, socket}
  end
end
