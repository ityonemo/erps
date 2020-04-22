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
  def upgrade(socket, _opts), do: {:ok, socket}

  @impl true
  @doc false
  def handshake(socket, _opts), do: {:ok, socket}

  @impl true
  @spec transport_type :: :none
  def transport_type, do: :none
end
