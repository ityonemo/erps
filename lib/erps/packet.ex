defmodule Erps.Packet do
  @moduledoc false

  # this is the construction of the erps packet, which looks as follows:
  #
  # bytes
  #
  # |  1   | 2     4 | 5           16 | 17          31 | 32     64 | 65        96 | 97  ...
  # |------|---------|----------------|----------------|-----------|--------------|---------
  # | type | version | rpc identifier | HMAC key       | signature | payload size | payload

  defstruct [:type,
    version:      "0.0.0",
    rpc_id:       "",
    hmac_key:     <<0::16 * 8>>,
    signature:    <<0::32 * 8>>,
    payload_size: 0,
    payload:      "",
  ]

  @type_to_code %{keepalive: 0, error: 1, call: 2, cast: 4, resp: 6, push: 8}
  @code_to_type %{0 => :keepalive, 1 => :error, 2 => :call, 4 => :cast, 8 => :push}
  @valid_codes Map.keys(@code_to_type)

  @type type ::
    :call | :cast | :push | :error | :keepalive

  @type t :: %__MODULE__{
    type:         type,
    version:      Version.t,
    rpc_id:       String.t,
    hmac_key:     String.t,
    signature:    binary,
    payload_size: non_neg_integer,
    payload:      term
  }

  @empty_key <<0::16 * 8>>
  @empty_sig <<0::32 * 8>>

  @spec decode(any) ::
          {:error, :badarg | <<_::64, _::_*8>>} | {:ok, Erps.Packet.t()} | Erps.Packet.t()
  def decode(<<0>>) do
    %__MODULE__{type: :keepalive}
  end
  def decode(packet, opts \\ [])
  def decode(packet = <<
      code, v1, v2, v3,
      rpc_ident::binary-size(12),
      hmac_key::binary-size(16),
      signature::binary-size(32),
      payload_size::32>> <> payload, opts)
      when (code in @valid_codes) and (:erlang.size(payload) == payload_size) do

    verification = opts[:verification]
    identifier = opts[:identifier]
    version_req = opts[:versions]
    binary_to_term = if opts[:safe] do
      &:erlang.binary_to_term(&1, [:safe])
    else
      &:erlang.binary_to_term/1
    end

    cond do
      # verify that we are doing the same rpc.
      identifier && (identifier != String.trim(rpc_ident, <<0>>)) ->
        {:error, "wrong rpc"}
      # verify that we are using an acceptable version
      version_req && (not Version.match?("#{v1}.#{v2}.#{v3}", version_req)) ->
        {:error, "incompatible version"}
      # if we care about auth, and don't provide it, die.
      (hmac_key == @empty_key || signature == @empty_sig) && verification ->
        {:error, "authentication required"}
      # if verified, go ahead and generate the packet.
      verification && verification.(empty_sig(packet), signature) ->
        binary_to_packet(packet, binary_to_term)
      verification ->
        {:error, "authentication failed"}
      # if we don't care about auth, fail if provided.
      hmac_key != @empty_key ->
        {:error, "authentication provided"}
      signature != @empty_sig ->
        {:error, "authentication provided"}
      # we didn't care about auth, and everything else matches.
      true ->
        binary_to_packet(packet, binary_to_term)
    end
  end
  def decode(<<code, _rest::binary>>, _) when code not in @valid_codes do
    {:error, "invalid code"}
  end
  def decode(_, _), do: {:error, "malformed packet"}

  defp empty_sig(<<prefix::binary-size(32), _ :: binary-size(32), rest :: binary>>) do
    <<prefix :: binary, @empty_sig :: binary, rest :: binary>>
  end

  defp binary_to_packet(
    <<code, v1, v2, v3,
    rpc_ident::binary-size(12),
    hmac_key::binary-size(16),
    signature::binary-size(32),
    payload_size::32, payload :: binary>>,
    binary_to_term) do

    {:ok, %__MODULE__{
      type:         @code_to_type[code],
      version:      "#{v1}.#{v2}.#{v3}",
      rpc_id:       String.trim(rpc_ident, <<0>>),
      hmac_key:     hmac_key,
      signature:    signature,
      payload_size: payload_size,
      payload:      binary_to_term.(payload)
    }}

  catch
    :error, :badarg ->
      {:error, :badarg}
  end

end
