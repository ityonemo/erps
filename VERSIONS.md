# Version changelog

## 0.1.0

- Completed the basic Erps protocol system

## 0.2.0

- Upgraded to using [`Plug.Crypto.non_executable_binary_to_term/2`](https://hexdocs.pm/plug_crypto/Plug.Crypto.html#non_executable_binary_to_term/2), according to the [ERLEF foundation security recommendations](https://erlef.github.io/security-wg/secure_coding_and_deployment_hardening/serialisation).

- Added warnings about HMAC system.
- (breaking) renamed vague `strategy` to `transport`
- Added `transport: false` option

## 0.2.1

- crash for calls if it's not connected yet.
- create `connected?` call

## 0.3.0

- switches to using an internal cache of hashed `GenServer.from` for
  interchange between Client and Server.  This makes it possible to use
  `Plug.Crypto.non_executable_binary_to_term/2` for unpickling values
  on the server-side.

## 0.3.1

- adds an extra optional term to `Erps.Server.reply/2` which lets you
  call it from outside of the server loop, for example, in async calls.

## 0.3.2

- (breaking) gives a custom way of changing the certificate inspection that
  provides access to socket directly.
- prevent the connections list from growing really big

## 0.3.3

- (breaking) change around the names of server options and improve documentation.
- add in `recv/2,3` callbacks to the transport APIs.
