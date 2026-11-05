#!/usr/bin/env ruby

# Exercise the exact Ruby program shown in the hardware report guide.
require 'open3'
require 'socket'
require 'tmpdir'

guide = File.read(File.expand_path('../../../docs/hardware-report.md', __dir__))
program = guide[/^    ruby <<'RUBY'\n(.*?)^    RUBY$/m, 1]
abort 'hardware report redactor not found in guide' unless program
program = program.lines.map { |line| line.delete_prefix('    ') }.join

host = Socket.gethostname
Dir.mktmpdir('hardware-redact-test') do |dir|
  fixture = <<~TEXT
    ahci0: Found disk serial="   SYNTH-123"
    Serial Number: ZZ-5678
    iSerialNumber 3 <USB-2233>
    path /dev/serno/NVME-123
    inet6 2001:db8::1:abcd%vtnet0
    inet6 2001:db8:1234:5678:abcd:ef01:2345:6789
    inet6 ::ffff:192.0.2.33
    endpoint [2001:db8::2]:443
    address at end of sentence: 2001:db8::dead.
    MAC 02:12:34:56:78:9a
    IPv4 192.0.2.34
    uuid 12345678-1234-1234-1234-123456789abc
    host #{host}
    fqdn #{host.split('.').first}.example.test
    builder@example:/home/builder/tree
    PCI vendor=0x8086 device=0x9a49
  TEXT
  File.write(File.join(dir, 'sample.txt'), fixture)
  stdout, stderr, status = Open3.capture3('ruby', '-', stdin_data: program, chdir: dir)
  abort "redactor failed: #{stdout} #{stderr}" unless status.success?
  output = File.read(File.join(dir, 'share', 'sample.txt'))
  mode = File.stat(File.join(dir, 'share', 'sample.txt')).mode & 0777
  abort "unexpected report permissions: #{mode.to_s(8)}" unless mode == 0600
  secrets = ['SYNTH-123', 'ZZ-5678', 'USB-2233', 'NVME-123',
             '2001:db8', '::ffff:', '192.0.2.', '02:12:34:56:78:9a',
             '12345678-1234-1234-1234-123456789abc', host, 'example.test',
             'builder@example:/home/builder/tree']
  secrets.each { |s| abort "not redacted: #{s}" if output.include?(s) }
  abort 'PCI ID was changed' unless output.include?('vendor=0x8086 device=0x9a49')
  abort 'original changed' unless File.read(File.join(dir, 'sample.txt')) == fixture
  _, _, second_run = Open3.capture3('ruby', '-', stdin_data: program, chdir: dir)
  abort 'existing report was not protected' if second_run.success?
  abort 'existing report changed' unless File.read(File.join(dir, 'share', 'sample.txt')) == output
  puts 'hardware report redaction: ok'
end
