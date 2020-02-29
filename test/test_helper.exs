__ENV__.file
|> Path.dirname
|> Path.join("scripts/test_rsa.exs")
|> Code.require_file

ExUnit.start()
