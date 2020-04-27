defmodule ErpsTest.Packet.EncodeTest do
  use ExUnit.Case, async: true

  # encoding tests will proceeed by taking a packet struct, encoding,
  # and then re-decoding on the other end.

  alias Erps.Packet

  @moduletag [packet: true, encode: true]

  defp strip_preamble(<<?e, ?r, ?p, ?s, _size :: 32>> <> rest), do: rest

  describe "when encoding a packet" do
    test "a very basic call is encoded" do
      assert {:ok, %Packet{type: :call, payload: "foobar"}} =
        %Packet{type: :call, payload: "foobar"}
        |> Packet.encode
        |> strip_preamble
        |> Packet.decode
    end

    test "a very basic cast is encoded" do
      assert {:ok, %Packet{type: :cast, payload: "foobar"}} =
        %Packet{type: :cast, payload: "foobar"}
        |> Packet.encode
        |> strip_preamble
        |> Packet.decode
    end

    test "a very basic error is encoded" do
      assert {:ok, %Packet{type: :error, payload: "foobar"}} =
        %Packet{type: :error, payload: "foobar"}
        |> Packet.encode
        |> strip_preamble
        |> Packet.decode
    end

    test "a very basic response is encoded" do
      assert {:ok, %Packet{type: :reply, payload: "foobar"}} =
        %Packet{type: :reply, payload: "foobar"}
        |> Packet.encode
        |> strip_preamble
        |> Packet.decode
    end

    test "a very basic push is encoded" do
      assert {:ok, %Packet{type: :push, payload: "foobar"}} =
        %Packet{type: :push, payload: "foobar"}
        |> Packet.encode
        |> strip_preamble
        |> Packet.decode
    end

    test "a keepalive is encoded" do
      assert {:ok, %Packet{type: :keepalive}} =
        %Packet{type: :keepalive}
        |> Packet.encode
        |> strip_preamble
        |> Packet.decode
    end
  end

  @version %Version{major: 1, minor: 3, patch: 4, pre: []}

  describe "the component" do
    test "version is encoded" do
      assert {:ok, %Packet{version: @version}} =
        %Packet{type: :call, version: @version}
        |> Packet.encode
        |> strip_preamble
        |> Packet.decode
    end

    test "identifier is encoded" do
      assert {:ok, %Packet{identifier: "identifier"}} =
        %Packet{type: :call, identifier: "identifier"}
        |> Packet.encode
        |> strip_preamble
        |> Packet.decode
    end
  end

  @payload {%{payload: "payload", loadpay: "fooled", payday: "failed", daycare: "duped"},
    :crypto.strong_rand_bytes(24), ["payload", "foolish"]}

  describe "when compression is turned on" do
    test "at the default level it's smaller" do
      uncompressed = Packet.encode(%Packet{type: :call, payload: @payload})
      compressed = Packet.encode(%Packet{type: :call, payload: @payload}, compressed: true)

      assert :erlang.size(uncompressed) > :erlang.size(compressed)

      assert {:ok, %Packet{payload: @payload}} = %Packet{type: :call, payload: @payload}
      |> Packet.encode(compressed: true)
      |> strip_preamble
      |> Packet.decode
    end

    test "at the highest level it's also small" do
      low_compressed = Packet.encode(%Packet{type: :call, payload: @payload}, compressed: 1)
      high_compressed = Packet.encode(%Packet{type: :call, payload: @payload}, compressed: 9)

      assert :erlang.size(low_compressed) > :erlang.size(high_compressed)

      assert {:ok, %Packet{payload: @payload}} = %Packet{type: :call, payload: @payload}
      |> Packet.encode(compressed: 9)
      |> strip_preamble
      |> Packet.decode
    end
  end
end
