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
  @callback upgrade!(:inet.socket, keyword) :: socket

  # SERVER API

  @doc """
  (server) opens a TCP port to listen for incoming connection requests.

  Opens the port in `active: false` to ensure correct synchronization of
  `c:handshake/2` and `c:upgrade!/2` events.

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
  @doc "Callback implementation for `c:Erps.Transport.Api.recv/2`, via `:gen_tcp.recv/2."
  defdelegate recv(sock, length), to: :gen_tcp

  @spec recv(socket, non_neg_integer, timeout) :: {:ok, binary} | {:error, term}
  @doc "Callback implementation for `c:Erps.Transport.Api.recv/3`, via `:gen_tcp.recv/3."
  defdelegate recv(sock, length, timeout), to: :gen_tcp

  @spec send(socket, iodata) :: :ok | {:error, term}
  @doc "Callback implementation for `c:Erps.Transport.Api.send/2`, via `:gen_tcp.send/2`"
  defdelegate send(sock, content), to: :gen_tcp

  @impl true
  @spec upgrade!(:inet.socket, keyword) :: Api.socket
  @doc """
  upgrades the socket to `active: true`.  Does not upgrade to an authenticated
  or encrypted channel.

  Callback implementation for `c:Erps.Transport.Api.upgrade!/2`.
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

  Callback implementation for `c:Erps.Transport.Api.upgrade!/2`.
  """
  def handshake(socket, _opts) do
    case :inet.setopts(socket, active: true) do
      :ok -> {:ok, socket}
      any -> any
    end
  end

  @impl true
  @spec transport_type :: :tcp
  def transport_type, do: :tcp
end

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
  @doc "Callback implementation for `c:Erps.Transport.Api.recv/2`, via `:ssl.recv/2."
  defdelegate recv(sock, length), to: :ssl

  @spec recv(socket, non_neg_integer, timeout) :: {:ok, binary} | {:error, term}
  @doc "Callback implementation for `c:Erps.Transport.Api.recv/3`, via `:ssl.recv/3."
  defdelegate recv(sock, length, timeout), to: :ssl

  @spec send(socket, iodata) :: :ok | {:error, term}
  @doc "Callback implementation for `c:Erps.Transport.Api.send/2`, via `:ssl.send/2`"
  defdelegate send(sock, content), to: :ssl

  @impl true
  @spec upgrade!(:inet.socket, keyword) :: Api.socket
  @doc """
  (client) responds to a server TLS `handshake/2` request, by upgrading to an encrypted connection.
  Verifies the identity of the server CA, and reject if it's not a valid peer.

  Callback implementation for `c:Erps.Transport.Api.upgrade!/2`.
  """
  def upgrade!(_, nil), do: raise "tls socket not configured"
  def upgrade!(socket, tls_opts) do
    # clients should always verify the identity of the server.
    with {:ok, tls_socket} <- :ssl.connect(socket, tls_opts ++ [verify: :verify_peer, fail_if_no_peer_cert: true]),
         :ok <- :ssl.setopts(tls_socket, active: true) do
         tls_socket
      else
      _ ->
        raise "tls socket upgrade error"
    end
  end

  @impl true
  @doc """
  (server) initiates a client `upgrade!/2` request, by upgrading to an encrypted connection.
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

defmodule Erps.Transport.Tls do

  @moduledoc """
  implements a two-way TLS transport strategy.

  this transport is useful when you have trusted clients and servers that are
  authenticated against each other and must have an encrypted channel over
  WAN.

  extra options:
  `:cert_verification` - an arity-2 function which gets passed the tls socket
    and the raw certificate for custom inspection.  If the certificate is
    rejected, then it should close the socket and output `{:error, term}`.
    if it's accepted, then it should output `{:ok, socket}`
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

  @spec upgrade!(socket, keyword) :: socket | no_return
  @doc "Callback implementation for `c:Erps.Transport.Api.upgrade!/2`, via `Erps.Transport.OneWayTls.upgrade!/2`."
  defdelegate upgrade!(sock, opts), to: Erps.Transport.OneWayTls

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
      cert_verification: &no_verification/2,
      verify: :verify_peer,
      fail_if_no_peer_cert: true,
    ], tls_opts!)

    with {:ok, tls_socket} <- :ssl.handshake(socket, tls_opts!, 200),
         :ok <- :ssl.setopts(tls_socket, active: true),
         {:ok, raw_certificate} <- :ssl.peercert(tls_socket) do

      tls_opts![:cert_verification].(socket, raw_certificate)

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

defmodule Erps.Transport.None do

  @moduledoc """
  implements no transport, which basically turns the Erps server into
  a basic GenServer
  """

  @behaviour Erps.Transport.Api

  @type socket :: Erps.Transport.Api.socket

  @impl true
  @doc false
  def listen(_port, _opts), do: {:ok, self()}
  @impl true
  @doc false
  def accept(sock, _timeout), do: {:ok, sock}

  @impl true
  @doc false
  def connect(_host, _port, _opts), do: {:ok, self()}

  @impl true
  def recv(_sock, _length), do: {:ok, ""}

  @impl true
  @doc "Callback implementation for `c:Erps.Transport.Api.recv/3`, via `:ssl.recv/3`."
  def recv(_sock, _length, _timeout), do: {:ok, ""}

  @impl true
  @doc false
  def send(_sock, _content), do: :ok

  @impl true
  @doc false
  def upgrade!(socket, _opts), do: socket

  @impl true
  @doc false
  def handshake(socket, _opts), do: {:ok, socket}

  @impl true
  @spec transport_type :: :none
  def transport_type, do: :none
end
