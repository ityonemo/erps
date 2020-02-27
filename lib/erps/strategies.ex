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
  @callback handshake!(:inet.socket, keyword) :: socket

  # DUAL API
  @callback send(socket, iodata) :: :ok | {:error, any}
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
  def upgrade!(socket, _opts), do: socket

  @impl true

  @spec handshake!(:inet.socket, keyword) :: StrategyApi.socket
  def handshake!(socket, _opts), do: socket

end

defmodule Erps.TLS do

  @behaviour Erps.StrategyApi
  alias Erps.StrategyApi

  defdelegate listen(port, opts), to: :gen_tcp
  defdelegate accept(sock, timeout), to: :gen_tcp
  defdelegate connect(host, port, opts), to: :gen_tcp
  defdelegate send(sock, content), to: :ssl


  @impl true
  @spec upgrade!(:inet.socket, keyword) :: StrategyApi.socket
  def upgrade!(socket, ssl_opts) do
    case :ssl.connect(socket, ssl_opts) do
      {:ok, ssl_socket} -> ssl_socket
      _ -> raise "ssl socket upgrade error"
    end
  end

  @impl true
  @spec handshake!(:inet.socket, keyword) :: StrategyApi.socket
  def handshake!(socket, ssl_opts) do
    case :ssl.handshake(socket, ssl_opts) do
      {:ok, ssl_socket} -> ssl_socket
      _ -> raise "ssl handshake error"
    end
  end

end

defmodule Erps.TwoWayTLS do

  @behaviour Erps.StrategyApi
  alias Erps.StrategyApi

  defdelegate listen(port, opts), to: :gen_tcp
  defdelegate accept(sock, timeout), to: :gen_tcp
  defdelegate connect(host, port, opts), to: :gen_tcp
  defdelegate send(sock, content), to: :ssl

  @impl true
  @spec upgrade!(:inet.socket, keyword) :: StrategyApi.socket
  def upgrade!(socket, ssl_opts) do
    case :ssl.connect(socket, ssl_opts) do
      {:ok, ssl_socket} -> ssl_socket
      _ -> raise "ssl socket upgrade error"
    end
  end

  @impl true
  @spec handshake!(:inet.socket, keyword) :: StrategyApi.socket
  def handshake!(socket, ssl_opts) do
    case :ssl.handshake(socket, ssl_opts ++
        [verify: :verify_peer,
        fail_if_no_peer_cert: true]) do
      {:ok, ssl_socket} -> ssl_socket
      _ -> raise "ssl handshake error"
    end
  end

end
