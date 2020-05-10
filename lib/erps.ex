defmodule Erps do

  @moduledoc """
  Erps is an OTP-compliant remote protocol service

  The general purpose of Erps is to extend the GenServer primitives over public
  networks using two-way TLS authentication and encryption *without* using OTP
  standard distribution, for cases when:

  1. Latency, reliability, or network toplogy properties make using the erlang
  distribution gossip protocol unfavorable or unreliable
  2. You prefer to use erlang distributed clusters strictly contain members
  of a given type, and have an orthogonal channel for cluster-to-cluster
  communication.
  3. You want to keep groups of Erlang nodes in isolation with a restricted
  protocol language to achieve security-in-depth and prevent privilege
  escalation across cluster boundaries.

  Erps is an *asymmetric* protocol, which means there are distinct roles for
  client and server.  An Erps client is a 'dumb proxy' for a remote GenServer,
  forwarding all of its `call/2` and `cast/2` requests to the Erps server.

  Erps is also a *persistent* protocol.  The clients are intended to connect in
  to the target server and indefinitely issue requests over this channel, (more
  like websockets) instead of instantiating a new connection per request, (like
  HTTP, JSON API, GRPC, or GraphQL).

  To that end, the Erps Client and Daemon support self-healing connections by
  default.

  ## Testability

  To make working with your program easier in developer or staging environments,
  Erps can be configured to use TCP.  In order to seamlessly switch between these
  transport modules, Erps uses the `Transport` library; both clients and servers
  may be launched with `transport: Transport.Tcp` to use this mode.

  ## Security model

  Erps currently presumes that once authenticated, both ends of the Erps
  connection are trusted, and provides only basic security measures to
  protect the server and the client.

  ## Distribution and Worker pools

  There are no provisions for supporting out-of-the-box 'smart' distribution
  defaults or smart worker pool defaults, but this is planned.

  ## Examples

  Examples on how to set up basic clients and servers are provided in
  in the documentation for `Erps.Client` and `Erps.Server`.  On the server side
  you must use an `Erps.Daemon` to serve as the entry-point for multiple
  connections which are individually managed by servers;  A Server cannot listen
  on a port for an inbound connection by itself.
  """
end
