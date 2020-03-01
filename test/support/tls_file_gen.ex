defmodule ErpsTest.TlsFileGen do

  def generate_key(dir, name) do
    ca_key = X509.PrivateKey.new_ec(:secp256r1)
    ca_key_pem_path = Path.join(dir, "#{name}.key")
    File.write!(ca_key_pem_path, X509.PrivateKey.to_pem(ca_key))
    ca_key
  end

  def generate_root(dir, name) do
    ca_key = generate_key(dir, name)

    ca = X509.Certificate.self_signed(ca_key,
      "/C=US/ST=CA/L=San Francisco/O=Acme/CN=CA_ROOT",
      template: :root_ca)
    ca_pem_path = Path.join(dir, "#{name}.pem")
    File.write!(ca_pem_path, X509.Certificate.to_pem(ca))

    {ca, ca_key}
  end

  def generate_cert(dir, name, ca, ca_key, opts \\ []) do
    key_bin = generate_key(dir, name)

    host = opts[:host] || "127.0.0.1"

    csr = X509.CSR.new(key_bin,
      "/C=US/ST=CA/L=San Francisco/O=Acme",
      extension_request: [
        X509.Certificate.Extension.subject_alt_name([host])])
    csr_path = Path.join(dir, "#{name}.csr")
    File.write!(csr_path, X509.CSR.to_pem(csr))

    cert = csr
    |> X509.CSR.public_key
    |> X509.Certificate.new(
      "/C=US/ST=CA/L=San Francisco/O=Acme",
      ca, ca_key, extensions: [
        subject_alt_name: X509.Certificate.Extension.subject_alt_name([host])
      ]
    )
    cert_path = Path.join(dir, "#{name}.cert")
    File.write!(cert_path, X509.Certificate.to_pem(cert))
  end
end