defmodule Erps.Packet do
  @moduledoc false

  defstruct [
    type:         :keepalive,
    version:      %Version{major: 0, minor: 0, patch: 0, pre: []},
    identifier:   "",
    hmac_key:     <<0::16 * 8>>,
    signature:    <<0::32 * 8>>,
    payload_size: 0,
    payload:      nil,
    complete?:    false,
  ]

  # this is the construction of the erps packet, which looks as follows:
  #
  # if the packet is a "keepalive" packet, the payload size should be zero and
  # no data should come after the type field.
  #
  # byte offset
  # | 0    3 | 4          7 |  8   || 9    11 | 12      47 | 48    63 | 64     95 | 96  ...
  # |--------|--------------|------||---------|------------|----------|-----------|---------
  # | cookie | payload size | type || version | identifier | HMAC key | signature | payload

  @magic_cookie <<?e, ?r, ?p, ?s>>
  @identifier_size 36
  @header_bytes 1 + 3 + @identifier_size + 16 + 32
  @packet_scan_timeout 100  # how frequently we should scan for packets
  @full_packet_timeout 500  # don't wait forever for the rest of the packet

  def get_data(transport, socket, opts) do
    timeout = opts[:timeout] || @packet_scan_timeout
    case transport.recv(socket, 0, timeout) do
      {:ok, @magic_cookie <> <<0::40>>} ->
        {:ok, %__MODULE__{}}  # return a keepalive packet in the base case.
      {:ok, @magic_cookie <> <<payload_size::32>> <> rest} when
          :erlang.size(rest) < (payload_size + @header_bytes) ->
        get_more(transport, socket, rest, payload_size, opts)
      {:ok, @magic_cookie <> <<payload_size::32>> <> rest} when
          :erlang.size(rest) == (payload_size + @header_bytes) ->
        decode(rest, opts)
      {:ok, _} ->
        # if there is no magic cookie or the size mismatches, declare an error.
        {:error, :einval}
      error -> error
    end
  end

  def get_more(transport, socket, first, payload_size, opts) do
    leftover_size = payload_size + @header_bytes - :erlang.size(first)
    case transport.recv(socket, leftover_size, @full_packet_timeout) do
      {:ok, rest} when :erlang.size(rest) == leftover_size ->
        [first, rest]
        |> IO.iodata_to_binary
        |> decode(opts)
      {:ok, _} ->
        # if the leftover size mismatches, throw it on the ground.
        {:error, :einval}
      error -> error
    end
  end

  @type_to_code %{error: 1, call: 4, cast: 8, reply: 2, push: 3}
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
    payload:      term,
    complete?:    boolean
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
  def decode(<<
      code, v1, v2, v3,
      identifier::binary-size(36),
      hmac_key::binary-size(16),
      signature::binary-size(32)>> <> payload, opts)
      when (code in @valid_codes) do

    # key options to use in our conditional checking pipeline
    verification = opts[:verification]
    srv_identifier = opts[:identifier]
    version_req = opts[:versions]

    # set the appropriate lambda to use for unpickling.
    binary_to_term = if opts[:safe] do
      &Plug.Crypto.non_executable_binary_to_term(&1, [:safe])
    else
      &:erlang.binary_to_term/1
    end

    version = %Version{major: v1, minor: v2, patch: v3, pre: []}

    # begin assembling the struct.
    struct_so_far = %__MODULE__{
      type: @code_to_type[code],
      version: version,
      identifier: trim(identifier),
      hmac_key: hmac_key,
      signature: signature,
      payload_size: :erlang.size(payload),
    }

    cond do
      # verify that we are using the same remote protocol.
      identifier_mismatches?(srv_identifier, struct_so_far) ->
        {:error, "wrong identifier"}
      # verify that we are using an acceptable version
      version_mismatches?(version_req, struct_so_far) ->
        {:error, "incompatible version"}
      # if verified, go ahead and generate the packet.
      verification ->
        {:error, "not implemented"}
        # if we don't care about auth, fail if provided.
      hmac_key != @empty_key ->
        {:error, "authentication provided"}
      signature != @empty_sig ->
        {:error, "authentication provided"}
      # we didn't care about auth, and everything else matches.
      true ->
        binary_to_packet(struct_so_far, payload, binary_to_term)
    end
  end
  def decode(<<code, _rest::binary>>, _) when code not in @valid_codes do
    {:error, :einval}
  end

  defp identifier_mismatches?(nil, _), do: false
  defp identifier_mismatches?(srv_identifier, struct_so_far) do
    srv_identifier != struct_so_far.identifier
  end

  defp version_mismatches?(nil, _), do: false
  defp version_mismatches?(version_req, struct_so_far) do
    not Version.match?(struct_so_far.version, version_req)
  end

  ##############################################################################

  @spec binary_to_packet(t, binary, (binary -> term)) :: {:ok, t} | {:error, :badarg}
  defp binary_to_packet(struct, payload, binary_to_term) do
    {:ok, %{struct | payload: binary_to_term.(payload)}}
  catch
    # return unsafe arguments as badarg.
    :error, :badarg ->
      {:error, :badarg}
  end

  #############################################################################

  @spec encode(t, keyword) :: iodata
  def encode(packet, opts \\ [])
  def encode(%__MODULE__{type: :keepalive}, _), do: <<@magic_cookie, 0 :: 40>>
  def encode(packet = %__MODULE__{}, opts) do
    type_code = @type_to_code[packet.type]
    padded_id = pad(packet.identifier)
    hmac_key = packet.hmac_key || @empty_key
    version = packet.version

    payload_binary = if opts[:compressed] do
      compression = if opts[:compressed] === true, do: :compressed, else: {:compressed, opts[:compressed]}
      :erlang.term_to_binary(packet.payload, [compression, minor_version: 2])
    else
      :erlang.term_to_binary(packet.payload)
    end
    payload_size = :erlang.size(payload_binary)

    assembled_binary =
      <<@magic_cookie, payload_size :: 32,
      type_code, version.major, version.minor, version.patch,
      padded_id :: binary, hmac_key :: binary,
      0::(32 * 8), payload_binary::binary>>

    sign_func = opts[:sign_with]
    if sign_func do
      raise "not implemented yet"
    else
      assembled_binary
    end
  end

  defp pad(string) do
    leftover = @identifier_size - :erlang.size(string)
    string <> <<0::(leftover * 8)>>
  end

  defp trim(binary) do
    prefix_size = :erlang.size(binary) - 1
    case binary do
        <<prefix::binary-size(prefix_size), 0>> -> trim(prefix)
        _ -> binary
    end
  end
end
