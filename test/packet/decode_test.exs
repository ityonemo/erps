defmodule ErpsTest.Packet.DecodeTest do
  use ExUnit.Case, async: true

  alias Erps.Packet

  @moduletag [packet: true, decode: true]

  @simplest_term []
  @simplest_payload :erlang.term_to_binary(@simplest_term)
  @empty_identifier <<0 :: 36 * 8>>
  @empty_signature <<0 :: 48 * 8>>

  # packet decoding occurs after the "payload size" term in the packet.
  #
  # byte offset
  # |   0  || 1     3 | 4       40 | 41    55 | 56     67 | 68  ...
  # |------||---------|------------|----------|-----------|---------
  # | type || version | identifier | HMAC key | signature | payload

  describe "when sending a call packet" do
    test "the most basic decode works" do
      assert {:ok, %Packet{type: :call, payload: []}} =
        Packet.decode(
          <<4, 0 :: 24, @empty_identifier, @empty_signature, @simplest_payload>>)
    end
  end

  describe "when filtering based on identifier" do
    @foo_identifier <<"foo", 0 :: 33 * 8>>

    test "identifiers decode" do
      assert {:ok, %Packet{type: :call, identifier: "foo", payload: []}} =
        Packet.decode(
          <<4, 0::24, @foo_identifier, @empty_signature, @simplest_payload>>)
    end

    test "matched identifiers succeed" do
      assert {:ok, %Packet{type: :call, identifier: "foo", payload: []}} =
        Packet.decode(<<4, 0::24, @foo_identifier, @empty_signature, @simplest_payload>>, identifier: "foo")
    end

    test "mismatched identifiers fail" do
      assert {:error, _} =
        Packet.decode(<<4, 0::24, @foo_identifier, @empty_signature, @simplest_payload>>, identifier: "bar")
    end
  end

  @version %Version{major: 0, minor: 1, patch: 0, pre: []}

  describe "when filtering based on versioning info" do
    test "versions decode" do
      assert {:ok, %Packet{type: :call, version: @version, payload: []}} =
        Packet.decode(<<4, 0, 1, 0, @empty_identifier, @empty_signature, @simplest_payload>>)
    end

    test "matched versions succeed" do
      assert {:ok, %Packet{type: :call, version: @version, payload: []}} =
        Packet.decode(<<4, 0, 1, 0, @empty_identifier, @empty_signature, @simplest_payload>>, versions: "== 0.1.0")
    end

    test "mismatched versions fail" do
      assert {:error, _} =
        Packet.decode(<<4, 0, 2, 0, @empty_identifier, @empty_signature, @simplest_payload>>, versions: "== 0.1.0")
    end
  end

  @barfooquux_atom <<131, 100, 0, 10, 98, 97, 114, 102, 111, 111, 113, 117, 117, 120>>
  @barfooquux_size :erlang.size(@barfooquux_atom)

  test "attempting to add an unknown atom fails in safe mode" do
    assert {:error, _} =
      Packet.decode(<<4, 0::24, @empty_identifier, @empty_signature, @barfooquux_atom>>, safe: true)
  end

  test "unknown codes result in a error" do
    assert {:error, _} =
      Packet.decode(<<7, 0::24, @empty_identifier, @empty_signature, @simplest_payload>>)
  end

  test "a single zero byte is a keepalive packet" do
    assert {:ok, %Packet{type: :keepalive}} = Packet.decode(<<0>>)
  end
end
