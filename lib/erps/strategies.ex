defmodule Erps.StrategyApi do
  @moduledoc false

  @type socket :: :inet.socket | :ssl.sslsocket

  # CLIENT API

  @callback connect(:inet.address, :inet.port_number, keyword)
  :: {:ok, socket} | {:error, any}
  @callback upgrade!(:inet.socket, keyword) :: socket

  # SERVER API

  @callback listen(:inet.port_number, keyword)
  :: {:ok, socket} | {:error, any}
  @callback accept(socket, timeout)
  :: {:ok, socket} | {:error, any}
  @callback handshake(:inet.socket, keyword) :: {:ok, socket} | {:error, any}

  # DUAL API
  @callback send(socket, iodata) :: :ok | {:error, any}
  @callback packet_type() :: :tcp | :ssl
end

defmodule Erps.TCP do

  @behaviour Erps.StrategyApi
  alias Erps.StrategyApi

  defdelegate listen(port, opts), to: :gen_tcp
  defdelegate accept(sock, timeout), to: :gen_tcp
  defdelegate connect(host, port, opts), to: :gen_tcp
  defdelegate send(sock, content), to: :gen_tcp

  @impl true
  @spec upgrade!(:inet.socket, keyword) :: StrategyApi.socket
  def upgrade!(socket, _opts) do
    :ok == :inet.setopts(socket, active: true) || raise "failure to activate socket!"
    socket
  end

  @impl true
  @spec handshake(:inet.socket, keyword) :: {:ok, StrategyApi.socket}
  def handshake(socket, _opts) do
    case :inet.setopts(socket, active: true) do
      :ok -> {:ok, socket}
      any -> any
    end
  end

  @impl true
  @spec packet_type :: :tcp
  def packet_type, do: :tcp
end

defmodule Erps.OneWayTLS do

  @behaviour Erps.StrategyApi
  alias Erps.StrategyApi

  defdelegate listen(port, opts), to: :gen_tcp
  defdelegate accept(sock, timeout), to: :gen_tcp
  defdelegate connect(host, port, opts), to: :gen_tcp
  defdelegate send(sock, content), to: :ssl

  @impl true
  @spec upgrade!(:inet.socket, keyword) :: StrategyApi.socket
  def upgrade!(socket, ssl_opts) do
    # clients should always verify the identity of the server.
    with {:ok, ssl_socket} <- :ssl.connect(socket, ssl_opts ++ [verify: :verify_peer, fail_if_no_peer_cert: true]),
         :ok <- :ssl.setopts(ssl_socket, active: true) do
         ssl_socket
      else
      _ ->
        raise "ssl socket upgrade error"
    end
  end

  @impl true
  @spec handshake(:inet.socket, keyword) :: {:ok, StrategyApi.socket} | {:error, any}
  def handshake(socket, ssl_opts) do
    with {:ok, ssl_socket} <- :ssl.handshake(socket, ssl_opts),
         :ok <- :ssl.setopts(ssl_socket, active: true) do
      {:ok, ssl_socket}
    else
      any ->
        :gen_tcp.close(socket)
        any
    end
  end

  @impl true
  @spec packet_type :: :ssl
  def packet_type, do: :ssl
end

defmodule Erps.TLS do

  @behaviour Erps.StrategyApi
  alias Erps.StrategyApi

  defdelegate listen(port, opts), to: :gen_tcp
  defdelegate accept(sock, timeout), to: :gen_tcp
  defdelegate connect(host, port, opts), to: :gen_tcp
  defdelegate send(sock, content), to: :ssl
  defdelegate upgrade!(sock, opts), to: Erps.OneWayTLS

  @impl true
  @spec handshake(:inet.socket, keyword) :: {:ok, StrategyApi.socket} | {:error, any}
  def handshake(socket, ssl_opts) do
    ssl_opts = Keyword.merge(ssl_opts, verify: :verify_peer, fail_if_no_peer_cert: true)
    with {:ok, ssl_socket} <- :ssl.handshake(socket, ssl_opts, 200),
         :ok <- :ssl.setopts(ssl_socket, active: true),
         {:ok, raw_certificate} <- :ssl.peercert(ssl_socket),
         {:ok, cert} <- X509.Certificate.from_der(raw_certificate),
         :ok <- verify_peer_ip(socket, cert) do
      {:ok, ssl_socket}
    else
      any ->
        :gen_tcp.close(socket)
        any
    end
  end

  @impl true
  @spec packet_type :: :ssl
  def packet_type, do: :ssl

  defp match_function({:ip, ip}, {:dNSName, dns}, ip), do: :inet.ntoa(ip) == dns
  defp match_function(_, _, _), do: :default

  def single_ip_check(ip), do: [match_fun: &match_function(&1, &2, ip)]

  @peer_dns {2, 5, 29, 17}
  def verify_peer_ip(socket, cert) do
    {:Extension, @peer_dns, false, [dNSName: cert_peer_ip]} =
      X509.Certificate.extension(cert, @peer_dns)
    {:ok, {peer, _port}} = :inet.peername(socket)
    if :inet.ntoa(peer) == cert_peer_ip, do: :ok, else: {:error, "invalid peername"}
  end
end
