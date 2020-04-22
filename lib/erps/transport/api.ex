defmodule Erps.Transport.Api do

  @moduledoc """
  Encapsulates a common API which describes a transport strategy.

  Currently the available transport strategies are:
  - `Erps.Transport.Tcp`: unencrypted, unauthenticated communication.  Only appropriate
    in `:dev` and `:test` environments.
  - `Erps.Transport.Tls`: two-way authenticated, encrypted communication, using X509
    TLS encryption.  This is the general use case for Erps, for point-to-point
    API services including over untrusted networks.
  - `Erps.Transport.OneWayTls`: one-way authenticated, encrypted communication, using
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
  @callback connect(:inet.ip_address, :inet.port_number, keyword)
  :: {:ok, socket} | {:error, any}

  @doc """
  (client) upgrades an TCP connection to an encrypted, authenticated
  connection.

  Also should upgrade the connection from `active: false` to `active: true`

  In the case of an unencrypted transport, e.g. `Erps.Transport.Tcp`, only perfroms the
  connection upgrade.
  """
  @callback upgrade(socket, keyword) :: {:ok, socket} | {:error, any}

  # SERVER API

  @doc """
  (server) opens a TCP port to listen for incoming connection requests.

  Opens the port in `active: false` to ensure correct synchronization of
  `c:handshake/2` and `c:upgrade/2` events.

  NB: tls options provided will be passed into listen to allow servers that
  require tls options to fail early when launching if the user doesn't supply
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
  (server) blocks the server waiting for a connection request until some data
  comes in.
  """
  @callback recv(socket, length :: non_neg_integer) :: {:ok, binary} | {:error, any}

  @doc """
  (server) Like `b:recv/2` but with a timeout so the server doesn't block
  indefinitely.
  """
  @callback recv(socket, length :: non_neg_integer, timeout) :: {:ok, binary} | {:error, any}

  @doc """
  (server) upgrades the TCP connection to an authenticated, encrypted
  connection.

  Also should upgrade the connection from `active: false` to `active: true`.

  In the case of an unencrypted transport, e.g. `Erps.Transport.Tcp`, only performs the
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
  @callback transport_type() :: :tcp | :ssl | :none

  @doc """
  a generic "listen" which calls `:gen_tcp.listen/2` that filters out any
  ssl options passed in (see `c:listen/2`)
  """
  def listen(port, options!) do
    options! = Enum.reject(options!, &match?({:tls_opts, _}, &1))
    :gen_tcp.listen(port, options!)
  end
end
