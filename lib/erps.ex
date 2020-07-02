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

  Erps currently presumes that once authenticated via TLS, both ends of the Erps
  connection are trusted, and provides only basic security measures to protect
  the server and the client.

  ## Distribution and Worker pools

  There are no provisions for supporting out-of-the-box 'smart' distribution
  defaults or smart worker pool defaults, but this is planned.

  ## Multiverses

  Erps supports `Multiverses` out of the box.  To activate multiverses at compile-
  time, you will probably want to have the following in your `test.exs`:

  ```
  config :erps, use_multiverses: true
  ```

  In order to use multiverses with any given Daemon or Client, you must also pass
  `forward_callers: true` in the options of the `Erps.Daemon.start/3`,
  `Erps.Daemon.start_link/3`, `Erps.Client.start/3`, `Erps.Client.start_link/3`
  functions.

  ## Examples

  Examples on how to set up basic clients and servers are provided in
  in the documentation for `Erps.Client` and `Erps.Server`.  On the server side
  you must use an `Erps.Daemon` to serve as the entry-point for multiple
  connections which are individually managed by servers;  A Server cannot listen
  on a port for an inbound connection by itself.
  """

  @doc """
  Tests to see if a `t:GenServer.from/0` tuple being passed into an Erps.Server
  is from a remote client

  usable in guards.
  """
  defguard is_remote(from) when is_tuple(elem(from, 1)) and
    elem(elem(from, 1), 0) == :"$remote_reply"

end
