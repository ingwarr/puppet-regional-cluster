#!/opt/puppetlabs/puppet/bin/ruby
# Offline privileged CA-client signing using installed openvoxserver-ca.
# Invoke as puppet, ONLY with both CA services stopped/fenced.
require 'openssl'
require 'fileutils'
require 'optparse'
require 'digest'
require 'time'
require 'json'
require 'securerandom'
require 'puppetserver/ca/local_certificate_authority'

options = { mode: 'check', ca_dir: '/srv/openvox-ca', certname: 'ca02.lab.example',
            san: 'DNS:puppet,DNS:ca02.lab.example' }
OptionParser.new do |o|
  o.on('--mode MODE', %w[check apply verify]) { |v| options[:mode] = v }
  o.on('--csr FILE') { |v| options[:csr] = v }
  o.on('--ca-dir DIR') { |v| options[:ca_dir] = v }
  o.on('--certname NAME') { |v| options[:certname] = v }
  o.on('--san CSV') { |v| options[:san] = v }
end.parse!

def abort_if(condition, message)
  abort("REFUSED: #{message}") if condition
end

def inventory_records(path)
  File.readlines(path).filter_map do |line|
    match = line.match(/\A(0x[0-9a-fA-F]+)\s+\S+\s+\S+\s+(.+)\s*\z/)
    match && [Integer(match[1], 16), match[2].strip]
  end
end

def serials_in_inventory(path)
  return [] unless File.exist?(path)
  File.readlines(path).filter_map do |line|
    token = line.split.first
    Integer(token, 16) rescue nil
  end
end

ca_dir = File.realpath(options[:ca_dir])
abort_if(ca_dir != '/var/lib/openvox-ca-sign-test',
         'test mode requires isolated CA directory')
abort_if(Process.uid == 0, 'run as puppet, never root')
abort_if(!options[:csr] || !File.file?(options[:csr]), 'CSR missing')
certname = options[:certname]
abort_if(certname != 'ca02.lab.example', 'unexpected certname')
abort_if(options[:san].split(',').map(&:strip).sort != %w[DNS:ca02.lab.example DNS:puppet].sort, 'unexpected SAN set')
csr = OpenSSL::X509::Request.new(File.binread(options[:csr]))
abort_if(!csr.verify(csr.public_key), 'CSR signature invalid')
abort_if(csr.subject.to_a.length != 1 || csr.subject.to_a[0][0] != 'CN' || csr.subject.to_a[0][1] != certname, 'CSR must contain only expected CN')
abort_if(csr.attributes.none? { |a| a.oid == 'extReq' || a.oid == 'msExtReq' }, 'CSR missing requested extensions')

requested_extensions = csr.attributes
  .select { |a| ['extReq', 'msExtReq', '1.2.840.113549.1.9.14'].include?(a.oid) }
  .flat_map do |attribute|
    attribute.value.value.flat_map do |item|
      item.value.map do |extension|
        OpenSSL::X509::Extension.new(extension)
      end
    end
  end

cli_oid = '1.3.6.1.4.1.34380.1.3.39'
cli_extensions = requested_extensions.select { |e| e.oid == cli_oid }
abort_if(cli_extensions.length != 1, 'CSR must request exactly one pp_cli_auth extension')
expected_cli_auth_der = OpenSSL::ASN1::UTF8String.new('true').to_der

abort_if(
  cli_extensions.first.value_der != expected_cli_auth_der,
  'CSR pp_cli_auth value is not the expected DER UTF8String true'
)

san_extensions = requested_extensions.select { |e| e.oid == 'subjectAltName' }
abort_if(san_extensions.length != 1, 'CSR must request exactly one SAN extension')

requested_sans = san_extensions.first.value.split(',').map(&:strip).sort
expected_sans = ['DNS:ca02.lab.example', 'DNS:puppet'].sort

abort_if(requested_sans != expected_sans, 'CSR SAN does not match expected names')

abort_if(csr.subject.to_a != [['CN', certname, 12]] && csr.subject.to_s != "/CN=#{certname}", 'CSR subject is not expected CN')

ca_cert_path = File.join(ca_dir, 'ca_crt.pem')
ca_key_path = File.join(ca_dir, 'ca_key.pem')
crl_path = File.join(ca_dir, 'ca_crl.pem')
serial_path = File.join(ca_dir, 'serial')
inventory_path = File.join(ca_dir, 'inventory.txt')
signed_path = File.join(ca_dir, 'signed', "#{certname}.pem")
[ca_cert_path, ca_key_path, crl_path, serial_path, inventory_path].each do |path|
  abort_if(!File.file?(path), "missing CA asset #{path}")
end
ca_cert = OpenSSL::X509::Certificate.new(File.binread(ca_cert_path))
ca_key = OpenSSL::PKey.read(File.binread(ca_key_path))
abort_if(ca_cert.public_key.to_der != ca_key.public_key.to_der, 'CA cert/key mismatch')
abort_if(Time.now >= ca_cert.not_after, 'CA certificate expired')
serial = Integer(File.read(serial_path).strip, 16)
existing_serials = serials_in_inventory(inventory_path)
abort_if(existing_serials.include?(serial), 'next serial already appears in inventory') if options[:mode] != 'verify'
abort_if(inventory_records(inventory_path).any? { |_, subject| subject == "/CN=#{certname}" } && options[:mode] != 'verify', 'certificate subject already in inventory')
abort_if(Dir.glob(File.join(ca_dir, 'signed', '*.pem')).any? { |path| OpenSSL::X509::Certificate.new(File.binread(path)).serial == serial } && options[:mode] != 'verify', 'next serial already used in signed certificates')
abort_if(File.exist?(signed_path) && options[:mode] != 'verify', 'signed certificate already exists')

if options[:mode] == 'verify'
  abort_if(!File.file?(signed_path), 'signed certificate missing')
  cert = OpenSSL::X509::Certificate.new(File.binread(signed_path))
  abort_if(!cert.verify(ca_cert.public_key), 'certificate signature invalid')
  abort_if(cert.public_key.to_der != csr.public_key.to_der, 'certificate public key differs from CSR')
  abort_if(cert.subject.to_s != csr.subject.to_s, 'certificate subject differs from CSR')
  ext = cert.extensions.find { |e| e.oid == '1.3.6.1.4.1.34380.1.3.39' }
  abort_if(ext.nil?, 'pp_cli_auth missing')
  sans = cert.extensions.find { |e| e.oid == 'subjectAltName' }
  abort_if(sans.nil? || !%w[puppet ca02.lab.example].all? { |n| sans.value.include?("DNS:#{n}") }, 'SAN mismatch')
  abort_if(inventory_records(inventory_path).count { |number, subject| number == cert.serial && subject == "/CN=#{certname}" } != 1, 'inventory entry must match serial and subject exactly once')
  abort_if(serial <= cert.serial, 'serial counter not advanced')
  abort_if(cert.extensions.count { |e| e.oid == '1.3.6.1.4.1.34380.1.3.39' } != 1, 'duplicate cli auth extension')
  abort_if(sans.value.split(/,\s*/).sort != ['DNS:ca02.lab.example', 'DNS:puppet'].sort, 'SAN must match exactly')
  abort_if(cert.not_before > Time.now || cert.not_after <= Time.now, 'certificate not currently valid')
  puts "VERIFIED #{certname}, serial=#{cert.serial.to_s(16)}, CA fingerprint=#{OpenSSL::Digest::SHA256.hexdigest(ca_cert.to_der)}"
  exit 0
end

puts "PREFLIGHT #{certname}, next serial=#{serial.to_s(16)}, CA fingerprint=#{OpenSSL::Digest::SHA256.hexdigest(ca_cert.to_der)}"
exit 0 if options[:mode] == 'check'
abort_if(options[:mode] != 'apply', 'unsupported mode')

# The caller must prove both CA services are stopped. The script also verifies
# that its local puppetserver is stopped; remote fencing is an Ansible responsibility.
abort_if(system('systemctl', 'is-active', '--quiet', 'puppetserver.service'), 'local puppetserver is active')

settings = {
  ca_ttl: 5 * 365 * 24 * 60 * 60,
  cacert: ca_cert_path, cakey: ca_key_path, cacrl: crl_path,
  serial: serial_path, cert_inventory: inventory_path,
  signeddir: File.join(ca_dir, 'signed'),
  csr_attributes: File.join(ca_dir, 'csr_attributes.yaml')
}
abort_if(File.file?(settings[:csr_attributes]) &&
         File.read(settings[:csr_attributes]).match?(/pp_cli_auth|1\.3\.6\.1\.4\.1\.34380\.1\.3\.39/),
         'CA-local csr_attributes may duplicate CLI auth extension')
ca = Puppetserver::Ca::LocalCertificateAuthority.new(OpenSSL::Digest::SHA256.new, settings)
abort_if(ca.respond_to?(:errors) && !ca.errors.empty?, "CA library errors: #{ca.errors.join('; ')}")
cert = ca.sign_authorized_cert(csr, options[:san])
abort_if(cert.nil?, 'library returned no certificate')
abort_if(cert.serial != serial, 'unexpected signed serial')
abort_if(!cert.verify(ca_cert.public_key), 'new certificate signature invalid')
abort_if(cert.public_key.to_der != csr.public_key.to_der, 'new certificate key mismatch')
auth = cert.extensions.find { |e| e.oid == '1.3.6.1.4.1.34380.1.3.39' }
abort_if(auth.nil?, 'new certificate missing cli auth')
san_ext = cert.extensions.find { |e| e.oid == 'subjectAltName' }
abort_if(san_ext.nil? || san_ext.value.split(/,\s*/).sort != ['DNS:ca02.lab.example', 'DNS:puppet'].sort, 'new certificate SAN mismatch')
abort_if(cert.extensions.count { |e| e.oid == '1.3.6.1.4.1.34380.1.3.39' } != 1, 'duplicate cli auth extension')

# Reserve the serial BEFORE publishing any certificate. If interrupted, the
# serial may be consumed without a cert. That gap is intentional and safe.
# Never decrease the serial or automatically roll back a partial commit.
# The operator must keep both CA services stopped throughout this operation.
abort_if(File.exist?(signed_path), 'certificate already exists before commit')
abort_if(File.read(serial_path).strip.to_i(16) != serial, 'serial changed during signing')
abort_if(serials_in_inventory(inventory_path).include?(serial), 'serial appeared in inventory during signing')
ca.update_serial_file(serial + 1)
warn "RESERVED serial=#{serial.to_s(16)}; do not roll back serial even if subsequent writes fail"

# Inventory first; final certificate published last. A failed write leaves a
# detectable incomplete state requiring manual inspection, never an auto-retry.
begin
  File.open(inventory_path, File::WRONLY | File::APPEND) do |f|
    f.write(ca.inventory_entry(cert) + "\n")
    f.flush
    f.fsync
  end
  File.open(signed_path, File::WRONLY | File::CREAT | File::EXCL, 0644) do |f|
    f.write(cert.to_pem)
    f.flush
    f.fsync
  end
rescue => e
  warn "PARTIAL COMMIT: #{e.class}: #{e.message}; DO NOT rerun apply or restart CA before inspection"
  raise
end
puts "SIGNED #{certname} serial=#{cert.serial.to_s(16)}; verify before restarting CA"
