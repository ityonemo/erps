defmodule Erps.Strategy.Api do

  @moduledoc """
  Encapsulates a common API which describes a transport strategy.

  Currently the available transport strategies are:
  - `Erps.Strategy.Tcp`: unencrypted, unauthenticated communication.  Only appropriate
    in `:dev` and `:test` environments.
  - `Erps.Strategy.Tls`: two-way authenticated, encrypted communication, using X509
    TLS encryption.  This is the general use case for Erps, for point-to-point
    API services including over untrusted networks.
  - `Erps.Strategy.OneWayTls`: one-way authenticated, encrypted communication, using
    X509 TLS encryption.  The server must present its authentication tokens
    and the clients may call in.  This is akin to traditional Web API or gRPC
    endpoints management, but still requires manual certificate distribution
    to your client endpoints.

  You may use this API to implement your own transport layers, or use it
  to mock responses in tests.

  Each of the API callbacks is either a client callback, a server callback,
  or a "both" callback.
  """

  @type socket :: :inet.socket | :ssl.sslsocket

  # CLIENT API

  @doc """
  (client) initiates a unencrypted connection from the client to the server.

  The connection must be opened with `active: false`, or upgrade guarantees
  cannot be ensured for X509-TLS connections.
  """
  @callback connect(:inet.address, :inet.port_number, keyword)
  :: {:ok, socket} | {:error, any}

  @doc """
  (client) upgrades an TCP connection to an encrypted, authenticated
  connection.

  Also should upgrade the connection from `active: false` to `active: true`

  In the case of an unencrypted strategy, e.g. `Erps.Strategy.Tcp`, only perfroms the
  connection upgrade.
  """
  @callback upgrade!(:inet.socket, keyword) :: socket

  # SERVER API

  @doc """
  (server) opens a TCP port to listen for incoming connection requests.

  Opens the port in `active: false` to ensure correct synchronization of
  `c:handshake/2` and `c:upgrade!/2` events.

  NB: ssl options provided will be passed into listen to allow servers that
  require ssl options to fail early when launching if the user doesn't supply
  them.
  """
  @callback listen(:inet.port_number, keyword)
  :: {:ok, socket} | {:error, any}

  @doc """
  (server) temporarily blocks the server waiting for a connection request.
  """
  @callback accept(socket, timeout)
  :: {:ok, socket} | {:error, any}

  @doc """
  (server) upgrades the TCP connection to an authenticated, encrypted
  connection.

  Also should upgrade the connection from `active: false` to `active: true`.

  In the case of an unencrypted strategy, e.g. `Erps.Strategy.Tcp`, only performs the
  connection upgrade.
  """
  @callback handshake(:inet.socket, keyword) :: {:ok, socket} | {:error, any}

  # DUAL API
  @doc "(both) sends a packet down the appropriate transport channel"
  @callback send(socket, iodata) :: :ok | {:error, any}
  @doc """
  (both) provides a hint to `c:GenServer.handle_info/2` as to what sorts of
  active packet messages to expect.
  """
  @callback packet_type() :: :tcp | :ssl

  @doc """
  a generic "listen" which calls `:gen_tcp.listen/2` that filters out any
  ssl options passed in (see `c:listen/2`)
  """
  def listen(port, options!) do
    options! = Enum.reject(options!, &match?({:ssl_opts, _}, &1))
    :gen_tcp.listen(port, options!)
  end
end

defmodule Erps.Strategy.Tcp do

  @moduledoc """
  implements a tcp transport strategy.
  """

  @behaviour Erps.Strategy.Api
  alias Erps.Strategy.Api

  @doc "Callback implementation for `c:Erps.Strategy.Api.listen/2`."
  defdelegate listen(port, opts), to: Api
  @doc "Callback implementation for `c:Erps.Strategy.Api.accept/2`."
  defdelegate accept(sock, timeout), to: :gen_tcp
  @doc "Callback implementation for `c:Erps.Strategy.Api.connect/3`."
  defdelegate connect(host, port, opts), to: :gen_tcp
  @doc "Callback implementation for `c:Erps.Strategy.Api.send/2`, via `:gen_tcp.send/2`"
  defdelegate send(sock, content), to: :gen_tcp

  @impl true
  @spec upgrade!(:inet.socket, keyword) :: Api.socket
  @doc """
  upgrades the socket to `active: true`.  Does not upgrade to an authenticated
  or encrypted channel.

  Callback implementation for `c:Erps.Strategy.Api.upgrade!/2`.
  """
  def upgrade!(socket, _opts) do
    :ok == :inet.setopts(socket, active: true) || raise "failure to activate socket!"
    socket
  end

  @impl true
  @spec handshake(:inet.socket, keyword) :: {:ok, Api.socket}
  @doc """
  upgrades the socket to `active: true`.  Does not request the client-side for an
  upgrade to an authenticated or encrypted channel.

  Callback implementation for `c:Erps.Strategy.Api.upgrade!/2`.
  """
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

defmodule Erps.Strategy.OneWayTls do

  @moduledoc """
  implements a one-way TLS transport strategy.

  this strategy is equivalent to a traditional http/grpc strategy, where a client
  does not have to be authenticated to a server, but the server must be
  authenticated to the client.

  WARNING: currently, there must exist a high level of trust between the client
  and the server, as certain attack vectors have not been closed yet.  Use at your
  own risk!
  """

  @behaviour Erps.Strategy.Api
  alias Erps.Strategy.Api

  @impl true
  @spec listen(:inet.port_number, keyword) :: {:ok, :inet.socket} | {:error, any}
  @doc """
  (server) opens a TCP port to listen for incoming connection requests.

  Verifies that the ssl options `:cacertfile`, `:certfile`, and `:keyfile` exist
  under the keyword `:ssl_opts`, and point to existing files (but not the validity
  of their authority chain or their crytographic signing).

  Callback implementation for `c:Erps.Strategy.Api.listen/2`.
  """
  def listen(port, opts) do
    # perform early basic validation of ssl options.
    ssl_opts = opts[:ssl_opts]
    unless ssl_opts, do: raise "ssl options not provided."
    verify_valid!(ssl_opts, :cacertfile)
    verify_valid!(ssl_opts, :certfile)
    verify_valid!(ssl_opts, :keyfile)
    Api.listen(port, opts)
  end

  defp verify_valid!(opt, key) do
    filepath = opt[key]
    unless filepath, do: raise "#{key} not provided"
    File.exists?(filepath) || raise "#{key} not a valid file"
  end

  @doc "Callback implementation for `c:Erps.Strategy.Api.accept/2`."
  defdelegate accept(sock, timeout), to: :gen_tcp
  @doc "Callback implementation for `c:Erps.Strategy.Api.connect/3`."
  defdelegate connect(host, port, opts), to: :gen_tcp
  @doc "Callback implementation for `c:Erps.Strategy.Api.send/2`, via `:ssl.send/2`"
  defdelegate send(sock, content), to: :ssl

  @impl true
  @spec upgrade!(:inet.socket, keyword) :: Api.socket
  @doc """
  (client) responds to a server TLS `handshake/2` request, by upgrading to an encrypted connection.
  Verifies the identity of the server CA, and reject if it's not a valid peer.

  Callback implementation for `c:Erps.Strategy.Api.upgrade!/2`.
  """
  def upgrade!(_, nil), do: raise "ssl socket not configured"
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
  @doc """
  (server) initiates a client `upgrade!/2` request, by upgrading to an encrypted connection.
  Performs no authentication of the client.

  Callback implementation for `c:Erps.Strategy.Api.handshake/2`.
  """
  @spec handshake(:inet.socket, keyword) :: {:ok, Api.socket} | {:error, any}
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

defmodule Erps.Strategy.Tls do

  @moduledoc """
  implements a two-way TLS transport strategy.

  this strategy is useful when you have trusted clients and servers that are
  authenticated against each other and must have an encrypted channel over
  WAN.
  """

  @behaviour Erps.Strategy.Api

  @doc "Callback implementation for `c:Erps.Strategy.Api.listen/2`, via `Erps.Strategy.OneWayTls.listen/2`."
  defdelegate listen(port, opts), to: Erps.Strategy.OneWayTls
  @doc "Callback implementation for `c:Erps.Strategy.Api.accept/2`."
  defdelegate accept(sock, timeout), to: :gen_tcp
  @doc "Callback implementation for `c:Erps.Strategy.Api.connect/3`."
  defdelegate connect(host, port, opts), to: :gen_tcp
  @doc "Callback implementation for `c:Erps.Strategy.Api.send/2`, via `:ssl.send/2`."
  defdelegate send(sock, content), to: :ssl
  @doc "Callback implementation for `c:Erps.Strategy.Api.upgrade!/2`, via `Erps.Strategy.OneWayTls.upgrade!/2`."
  defdelegate upgrade!(sock, opts), to: Erps.Strategy.OneWayTls

  @impl true
  @spec handshake(:inet.socket, keyword) :: {:ok, Api.socket} | {:error, any}
  @doc """
  (server) a specialized function that generates a match function option used to
  verify that the incoming client is bound to a single ip address.
  """
  def handshake(socket, ssl_opts!) do
    # instrument in a series of default ssl options into the handshake.
    ssl_opts! = Keyword.merge([
      ip_verification_fun: &verify_peer_ip/2,
      verify: :verify_peer,
      fail_if_no_peer_cert: true,
    ], ssl_opts!)

    with {:ok, ssl_socket} <- :ssl.handshake(socket, ssl_opts!, 200),
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

  defp match_function({:ip, ip}, {:dNSName, _}, ip), do: true
  defp match_function(_, _, _), do: false

  @spec single_ip_check(:inet.ip_address) ::
    [match_fun: (({:ip, :inet.ip_address}, {:dNSName, charlist}) -> boolean)]
  @doc """
  (client) a specialized function that generates a match function option used to
  verify that the targetted server is bound to a single ip address.

  should be used as in as the `:customize_hostname_check` option for clients
  """
  def single_ip_check(ip), do: [match_fun: &match_function(&1, &2, ip)]

  @peer_dns {2, 5, 29, 17}
  defp verify_peer_ip(socket, cert) do
    {:Extension, @peer_dns, false, [dNSName: cert_peer_ip]} =
      X509.Certificate.extension(cert, @peer_dns)
    {:ok, {peer, _port}} = :inet.peername(socket)
    if :inet.ntoa(peer) == cert_peer_ip, do: :ok, else: {:error, "invalid peername"}
  end
end
