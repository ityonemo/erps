require Logger

tempdir_name = Base.encode16(:crypto.strong_rand_bytes(32))
tempdir = Path.join("/tmp/.erps-test", tempdir_name)
File.mkdir_p!(tempdir)

Logger.info("test certificates path: #{tempdir}")

# make your own CA

ca_key = X509.PrivateKey.new_ec(:secp256r1)
ca_key_pem_path = Path.join(tempdir, "rootCA.key")
File.write!(ca_key_pem_path, X509.PrivateKey.to_pem(ca_key))

ca = X509.Certificate.self_signed(ca_key,
  "/C=US/ST=CA/L=San Francisco/O=Acme/CN=ECDSA Root CA",
  template: :root_ca)
ca_pem_path = Path.join(tempdir, "rootCA.pem")
File.write!(ca_pem_path, X509.Certificate.to_pem(ca))

# generate server authentications
server_key = X509.PrivateKey.new_ec(:secp256r1)
server_key_pem_path = Path.join(tempdir, "server.key")
File.write!(server_key_pem_path, X509.PrivateKey.to_pem(ca_key))

server_csr = X509.CSR.new(server_key,
  "/C=US/ST=CA/L=San Francisco/O=Acme",
  extension_request: [
    X509.Certificate.Extension.subject_alt_name(["127.0.0.1"])])
server_csr_path = Path.join(tempdir, "server.csr")
File.write!(server_csr_path, X509.CSR.to_pem(server_csr))

server_cert = server_csr
|> X509.CSR.public_key
|> X509.Certificate.new(
  "/C=US/ST=CA/L=San Francisco/O=Acme",
  ca, ca_key, extensions: [
    subject_alt_name: X509.Certificate.Extension.subject_alt_name(["127.0.0.1"])
  ]
)
server_cert_path = Path.join(tempdir, "server.cert")
File.write!(server_cert_path, X509.Certificate.to_pem(server_cert))

# generate client authentications
client_key = X509.PrivateKey.new_ec(:secp256r1)
client_key_pem_path = Path.join(tempdir, "client.key")
File.write!(client_key_pem_path, X509.PrivateKey.to_pem(ca_key))

client_csr = X509.CSR.new(client_key,
  "/C=US/ST=CA/L=San Francisco/O=Acme",
  extension_request: [
    X509.Certificate.Extension.subject_alt_name(["127.0.0.1"])])
client_csr_path = Path.join(tempdir, "client.csr")
File.write!(client_csr_path, X509.CSR.to_pem(client_csr))

client_cert = client_csr
|> X509.CSR.public_key
|> X509.Certificate.new(
  "/C=US/ST=CA/L=San Francisco/O=Acme",
  ca, ca_key, extensions: [
    subject_alt_name: X509.Certificate.Extension.subject_alt_name(["127.0.0.1"])
  ]
)
client_cert_path = Path.join(tempdir, "client.cert")
File.write!(client_cert_path, X509.Certificate.to_pem(client_cert))

defmodule ErpsTest.TlsFiles do
  @path tempdir
  def path, do: @path
end
