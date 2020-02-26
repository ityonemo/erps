defmodule ErpsTest.Packet.DecodeTest do
  use ExUnit.Case, async: true

  alias Erps.Packet

  @moduletag [packet: true, decode: true]

  @simplest_term []
  @simplest_payload :erlang.term_to_binary(@simplest_term)


  describe "when sending a call packet" do
    test "the most basic decode works" do
      assert {:ok, %Packet{type: :call, payload: []}} =
        Packet.decode(<<4, 0::(63 * 8), 2::32, @simplest_payload>>)
    end
  end

  describe "when filtering based on rpc identifier" do
    test "identifiers decode" do
      assert {:ok, %Packet{type: :call, identifier: "foo", payload: []}} =
        Packet.decode(<<4, 0::24, "foo", 0::(9 * 8), 0::(48 * 8), 2::32, @simplest_payload>>)
    end

    test "matched identifiers succeed" do
      assert {:ok, %Packet{type: :call, identifier: "foo", payload: []}} =
        Packet.decode(<<4, 0::24, "foo", 0::(9 * 8), 0::(48 * 8), 2::32, @simplest_payload>>, identifier: "foo")
    end

    test "mismatched identifiers fail" do
      assert {:error, _} =
        Packet.decode(<<4, 0::24, "foo", 0::(9 * 8), 0::(48 * 8), 2::32, @simplest_payload>>, identifier: "bar")
    end
  end

  @version %Version{major: 0, minor: 1, patch: 0, pre: []}

  describe "when filtering based on versioning info" do
    test "versions decode" do
      assert {:ok, %Packet{type: :call, version: @version, payload: []}} =
        Packet.decode(<<4, 0, 1, 0, 0::(60 * 8), 2::32, @simplest_payload>>)
    end

    test "matched versions succeed" do
      assert {:ok, %Packet{type: :call, version: @version, payload: []}} =
        Packet.decode(<<4, 0, 1, 0, 0::(60 * 8), 2::32, @simplest_payload>>, versions: "== 0.1.0")
    end

    test "mismatched versions fail" do
      assert {:error, _} =
        Packet.decode(<<4, 0, 2, 0, 0::(60 * 8), 2::32, @simplest_payload>>, versions: "== 0.1.0")
    end
  end

  @hmac_key fn -> Enum.random(?A..?Z) end |> Stream.repeatedly |> Enum.take(16) |> List.to_string
  @hmac_secret :crypto.strong_rand_bytes(32)

  defp signature_function(binary) do
    :crypto.mac(:hmac, :sha256, @hmac_secret, binary)
  end

  defp vfn(binary, @hmac_key, signature) do
    signature == signature_function(binary)
  end

  describe "hmac authentication can be provided" do
    test "matched signatures succeed" do
      signature = signature_function(<<4, 0::(15 * 8), @hmac_key, 0 ::(32 * 8), 2::32, @simplest_payload>>)

      assert {:ok, %Packet{type: :call, payload: []}} =
        Packet.decode(<<4, 0::(15 * 8), @hmac_key, signature::binary, 2::32, @simplest_payload>>, verification: &vfn/3)
    end

    test "mismatched signatures fail" do
      signature = signature_function(<<2, 0::(15 * 8), @hmac_key, 0 ::(32 * 8), 2::32, @simplest_payload>>)

      # generate a bad signature by changing the first byte to zero.
      sig_rest = :binary.part(signature, {1, 31})
      bad_sig = <<0>> <> sig_rest

      assert {:error, _} =
        Packet.decode(<<4, 0::(15 * 8), @hmac_key, bad_sig::binary, 2::32, @simplest_payload>>, verification: &vfn/3)
    end
  end

  @barfooquux_atom <<131, 100, 0, 10, 98, 97, 114, 102, 111, 111, 113, 117, 117, 120>>
  @barfooquux_size :erlang.size(@barfooquux_atom)

  test "attempting to add an unknown atom fails in safe mode" do
    assert {:error, _} =
      Packet.decode(<<4, 0::(63 * 8), @barfooquux_size :: 32, @barfooquux_atom>>, safe: true)
  end

  test "unknown codes result in a error" do
    assert {:error, _} =
      Packet.decode(<<7, 0::(63 * 8), 2::32, @simplest_payload>>)
  end

  test "malformed packets result in an error" do
    assert {:error, _} =
      Packet.decode(<<4, 0::(63 * 8), 2::32, @simplest_payload, 0>>)
  end

  test "a single zero byte is a keepalive packet" do
    assert {:ok, %Packet{type: :keepalive}} = Packet.decode(<<0>>)
  end
end
