# frozen_string_literal: true
require 'tmpdir'
require_relative '../libexec/contiguous-progress'

def control(bits, total = 4096, piece = 1024)
  [1, 0, 0, piece, total, 0, bits.bytesize].pack('nNNNQ>Q>N') + bits.b + [0].pack('N')
end

def assert(value, message)
  raise message unless value
end

assert(ContiguousProgress.confirmed_prefix(control("\xa0")) == 1024, 'must stop at first gap')
assert(ContiguousProgress.confirmed_prefix(control("\x70")) == 0, 'later pieces are not a prefix')
assert(ContiguousProgress.confirmed_prefix(control("\xf0")) == 4095, 'must withhold total size')
assert(ContiguousProgress.confirmed_prefix(control("\xc0")) == 2048, 'MSB-first bit order')
assert(ContiguousProgress.confirmed_prefix(control("\xf0", 3500)) == 3499, 'short final piece')
assert(ContiguousProgress.confirmed_prefix(control("\xf0")[0, 34]).nil?, 'truncated bitfield')
assert(ContiguousProgress.confirmed_prefix(control("\xf0").sub("\x00\x01".b, "\x00\x02".b)).nil?, 'unknown format')
assert(ContiguousProgress.confirmed_prefix(control("\xf0", 4096, 0)).nil?, 'zero piece length')
Dir.mktmpdir do |dir|
  data = ('a' * 1024) + ('b' * 1024) + ('c' * 1024) + ('d' * 1024)
  File.binwrite("#{dir}/data", data)
  File.binwrite("#{dir}/data.aria2", control("\xa0"))
  destination = "#{dir}/out"
  ContiguousProgress.mirror(dir, destination)
  assert(File.binread(destination) == data[0, 1024], 'copy only actual completed prefix')
  File.binwrite("#{dir}/data.aria2", control("\xc0"))
  ContiguousProgress.mirror(dir, destination)
  assert(File.binread(destination) == data[0, 2048], 'append next completed piece')
  File.binwrite("#{dir}/data.aria2", 'unsupported')
  ContiguousProgress.mirror(dir, destination)
  assert(File.size(destination) == 2048, 'malformed state leaves partial unchanged')
  File.unlink(destination)
  File.symlink("#{dir}/data", destination)
  ContiguousProgress.mirror(dir, destination)
  assert(File.size("#{dir}/data") == 4096, 'do not follow output symlink')
end
assert(ContiguousProgress.run('/missing', '/missing', [RbConfig.ruby, '-e', 'exit 8']) == 8, 'preserve retry exit code')
puts 'PASS: completed-prefix parser, gap isolation, malformed state, symlinks and exit codes'
