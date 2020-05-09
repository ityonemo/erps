defmodule Erps do

  @moduledoc """
  Erps is an OTP-compliant remote protocol service

  The general purpose of Erps is to extend the GenServer primitives over public
  networks using TLS authentication and encryption *without* using OTP standard
  distribution, for cases when

  1. latency, reliability, or network toplogy properties make using erlang
  distribution unfavorable or unreliable
  2. you prefer to use erlang distributed clusters strictly contain members
  of a given type, and have an orthogonal channel for cluster-to-cluster
  communication.

  Erps is an *asymmetric* protocol, which means there are distinct roles for
  client and server.  An Erps client is a 'dumb proxy' for a remote GenServer,
  forwarding all of its `call/2` and `cast/2` requests to the Erps server.

  ## Security model

  Erps currently presumes that once authenticated, both ends of the Erps
  connection are trusted, and provides only basic security measures to
  protect the server and the client.

  In particular, one of the strategies, `Transport.OneWayTls`, is still
  in-progress but should be considered experimental and insecure.  Updates
  to improve the security model of this stratgy are welcome.

  ## Distribution and Worker pools

  There are no provisions for supporting out-of-the-box 'smart' distribution
  defaults or smart worker pool defaults, but this is planned.

  ## Examples

  Examples on how to set up basic clients and servers are provided in
  in the documentation for `Erps.Client` and `Erps.Server`
  """

  @typedoc false
  @type socket :: :inet.socket | :ssl.socket
end
