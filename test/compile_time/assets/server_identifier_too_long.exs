defmodule ServerIdentifierTooLong do
  use Erps.Server, identifier: "toomanycharactershere"

  def start_link(_), do: Erps.Server.start_link(__MODULE__, :ok)

  @impl true
  def init(_), do: {:ok, :ok}
end
