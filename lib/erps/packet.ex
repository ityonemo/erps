defmodule Erps.Packet do
  @moduledoc false

  # this is the construction of the erps packet, which looks as follows:
  #
  # bytes
  #
  # |  1   | 2     4 | 5           16 | 17          31 | 32     64 | 65        96 | 97  ...
  # |------|---------|----------------|----------------|-----------|--------------|---------
  # | type | version | rpc identifier | HMAC key       | signature | payload size | payload

  defstruct [
    type:         :keepalive,
    version:      %Version{major: 0, minor: 0, patch: 0, pre: []},
    identifier:   "",
    hmac_key:     <<0::16 * 8>>,
    signature:    <<0::32 * 8>>,
    payload_size: 0,
    payload:      "",
  ]

  @type_to_code %{keepalive: 0, error: 1, call: 4, cast: 8, reply: 2, push: 3}
  @code_to_type %{0 => :keepalive, 1 => :error, 4 => :call, 8 => :cast, 2 => :reply, 3 => :push}
  @valid_codes Map.keys(@code_to_type)

  @type type ::
    :call | :cast | :push | :reply | :error | :keepalive

  @type t :: %__MODULE__{
    type:         type,
    version:      Version.t,
    identifier:   String.t,
    hmac_key:     String.t,
    signature:    binary,
    payload_size: non_neg_integer,
    payload:      term
  }

  @empty_key <<0::16 * 8>>
  @empty_sig <<0::32 * 8>>

  @type decode_option ::
    {:verification, (binary, binary -> boolean)} |
    {:identifier, String.t} |
    {:versions, String.t} |
    {:safe, boolean}

  #############################################################################
  ## DECODING

  @spec decode(binary, [decode_option]) :: {:error, term} | {:ok, t}
  def decode(packet, opts \\ [])
  def decode(<<0>>, _) do
    {:ok, %__MODULE__{type: :keepalive}}
  end
  def decode(packet = <<
      code, v1, v2, v3,
      pkt_identifier::binary-size(12),
      hmac_key::binary-size(16),
      signature::binary-size(32),
      payload_size::32>> <> payload, opts)
      when (code in @valid_codes) and (:erlang.size(payload) == payload_size) do

    # key options to use in our conditional checking pipeline
    verification = opts[:verification]
    srv_identifier = opts[:identifier]
    version_req = opts[:versions]

    # set the appropriate lambda to use for unpickling.
    binary_to_term = if opts[:safe] do
      &:erlang.binary_to_term(&1, [:safe])
    else
      &:erlang.binary_to_term/1
    end

    cond do
      # verify that we are doing the same rpc.
      srv_identifier && (srv_identifier != String.trim(pkt_identifier, <<0>>)) ->
        {:error, "wrong rpc"}
      # verify that we are using an acceptable version
      version_req && (not Version.match?("#{v1}.#{v2}.#{v3}", version_req)) ->
        {:error, "incompatible version"}
      # if we care about auth, and don't provide it, die.
      (hmac_key == @empty_key || signature == @empty_sig) && verification ->
        {:error, "authentication required"}
      # if verified, go ahead and generate the packet.
      verification && verification.(empty_sig(packet), hmac_key, signature) ->
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

  ##############################################################################

  @doc false
  @spec empty_sig(binary) :: binary
  def empty_sig(<<prefix::binary-size(32), _ :: binary-size(32), rest :: binary>>) do
    <<prefix :: binary, @empty_sig :: binary, rest :: binary>>
  end

  @spec binary_to_packet(binary, (binary -> term)) :: {:ok, t} | {:error, :badarg}
  defp binary_to_packet(
    <<code, v1, v2, v3,
    identifier::binary-size(12),
    hmac_key::binary-size(16),
    signature::binary-size(32),
    payload_size::32, payload :: binary>>,
    binary_to_term) do

    {:ok, %__MODULE__{
      type:         @code_to_type[code],
      version:      %Version{major: v1, minor: v2, patch: v3, pre: []},
      identifier:   String.trim(identifier, <<0>>),
      hmac_key:     hmac_key,
      signature:    signature,
      payload_size: payload_size,
      payload:      binary_to_term.(payload)
    }}

  catch
    # return unsafe arguments as badarg.
    :error, :badarg ->
      {:error, :badarg}
  end

  #############################################################################

  @spec encode(t, keyword) :: iodata
  def encode(packet, opts \\ [])
  def encode(%__MODULE__{type: :keepalive}, _), do: <<0>>
  def encode(packet = %__MODULE__{}, opts) do
    type_code = @type_to_code[packet.type]
    padded_id = pad(packet.identifier)
    hmac_key = packet.hmac_key
    version = packet.version

    payload_binary = if opts[:compressed] do
      compression = if (opts[:compressed] === true), do: :compressed, else: {:compressed, opts[:compressed]}
      :erlang.term_to_binary(packet.payload, [compression, minor_version: 2])
    else
      :erlang.term_to_binary(packet.payload)
    end
    payload_size = :erlang.size(payload_binary)

    assembled_binary =
      <<type_code, version.major, version.minor, version.patch,
      padded_id :: binary, hmac_key :: binary,
      0::(32 * 8), payload_size :: 32,
      payload_binary::binary>>

    sign_func = opts[:sign_with]
    if sign_func do
      [type_code, version.major, version.minor, version.patch, padded_id,
       packet.hmac_key, sign_func.(assembled_binary),
       <<payload_size :: 32>>, payload_binary]
    else
      assembled_binary
    end
  end

  defp pad(string) do
    leftover = 12 - :erlang.size(string)
    string <> <<0::(leftover * 8)>>
  end

end
