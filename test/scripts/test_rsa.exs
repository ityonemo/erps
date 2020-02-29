require Logger

tempdir_name = Base.encode16(:crypto.strong_rand_bytes(32))
tempdir = Path.join([System.tmp_dir!(), ".erps-test", tempdir_name])

ExUnit.after_suite(fn %{failures: 0} ->
  # only clean up our temporary directory if it was succesful
  System.tmp_dir!()
  |> Path.join(".erps-test")
  |> File.rm_rf!()
  :ok
  _ -> :ok
end)

File.mkdir_p!(tempdir)

Logger.info("test certificates path: #{tempdir}")

# make your own CA
{ca, ca_key} = ErpsTest.TlsFileGen.generate_root(tempdir, "rootCA")
# generate server authentications
ErpsTest.TlsFileGen.generate_cert(tempdir, "server", ca, ca_key)
# generate client authentications
ErpsTest.TlsFileGen.generate_cert(tempdir, "client", ca, ca_key)

# generate a key that is unrelated to the correct keys.
ErpsTest.TlsFileGen.generate_key(tempdir, "wrong-key")

# generate a client and cert that has wrong hosts.
ErpsTest.TlsFileGen.generate_cert(tempdir, "wrong-host", ca, ca_key, host: "1.1.1.1")

# make a chain of content that comes from the wrong CA root
{wrong_ca, wrong_ca_key} = ErpsTest.TlsFileGen.generate_root(tempdir, "wrong-rootCA")
# generate server authentications
ErpsTest.TlsFileGen.generate_cert(tempdir, "wrong-root-server", wrong_ca, wrong_ca_key)
# generate client authentications
ErpsTest.TlsFileGen.generate_cert(tempdir, "wrong-root-client", wrong_ca, wrong_ca_key)

defmodule ErpsTest.TlsFiles do
  @path tempdir
  def path, do: @path
end
