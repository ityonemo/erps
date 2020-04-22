
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

  @spec listen(:inet.port_number, keyword) :: {:ok, socket} | {:error, term}
  @doc "Callback implementation for `c:Erps.Transport.Api.listen/2`, via `Erps.Transport.OneWayTls.listen/2`."
  defdelegate listen(port, opts), to: Erps.Transport.OneWayTls

  @spec accept(socket, timeout) :: {:ok, socket} | {:error, term}
  @doc "Callback implementation for `c:Erps.Transport.Api.accept/2`."
  defdelegate accept(sock, timeout), to: :gen_tcp

  @spec connect(term, :inet.port_number, keyword) :: {:ok, socket} | {:error, term}
  @doc "Callback implementation for `c:Erps.Transport.Api.connect/3`."
  defdelegate connect(host, port, opts), to: :gen_tcp

  @spec send(socket, iodata) :: :ok | {:error, term}
  @doc "Callback implementation for `c:Erps.Transport.Api.send/2`, via `:ssl.send/2`."
  defdelegate send(sock, content), to: :ssl

  @spec upgrade(socket, keyword) :: {:ok, socket} | {:error, term}
  @doc "Callback implementation for `c:Erps.Transport.Api.upgrade/2`, via `Erps.Transport.OneWayTls.upgrade/2`."
  defdelegate upgrade(sock, opts), to: Erps.Transport.OneWayTls

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

    with {:ok, tls_socket} <- :ssl.handshake(socket, tls_opts!, 200),
         :ok <- :ssl.setopts(tls_socket, active: true),
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
