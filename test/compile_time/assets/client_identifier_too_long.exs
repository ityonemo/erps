defmodule ClientIdentifierTooLong do
  use Erps.Client, identifier: "toomanycharactershere"

  def start_link(_), do: Erps.Client.start_link(__MODULE__, :ok)

  @impl true
  def init(_), do: {:ok, :ok}
end
