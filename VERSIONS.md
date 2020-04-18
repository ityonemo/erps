# Version changelog

## 0.1.0

- Completed the basic Erps protocol system

## 0.2.0

- Upgraded to using [`Plug.Crypto.non_executable_binary_to_term/2`](https://hexdocs.pm/plug_crypto/Plug.Crypto.html#non_executable_binary_to_term/2), according to the [ERLEF foundation security recommendations](https://erlef.github.io/security-wg/secure_coding_and_deployment_hardening/serialisation).

- Added warnings about HMAC system.
- (breaking) renamed vague `strategy` to `transport`
- Added `transport: false` option
