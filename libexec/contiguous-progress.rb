# frozen_string_literal: true
# Supervise aria2 and expose only a confirmed contiguous prefix to Homebrew.
# aria2's v1 HTTP control file uses network byte order and MSB-first bitfields:
# https://github.com/aria2/aria2/blob/master/src/DefaultBtProgressInfoFile.cc
# Unknown/malformed formats fail closed: keep downloading, skip mirroring.
module ContiguousProgress
  MAX_CONTROL_SIZE = 16 * 1024 * 1024

  def self.confirmed_prefix(control)
    return nil unless control.bytesize >= 38
    version, extension, hash_length = control.unpack('nNN')
    return nil unless version == 1 && extension == 0 && hash_length == 0

    piece_length, total, _uploaded, length = control.byteslice(10, 24).unpack('NQ>Q>N')
    return nil if piece_length.zero? || total.zero?
    pieces = (total + piece_length - 1) / piece_length
    return nil unless length == (pieces + 7) / 8 && 34 + length + 4 <= control.bytesize

    bitfield = control.byteslice(34, length)
    complete = 0
    while complete < pieces && (bitfield.getbyte(complete / 8) & (0x80 >> (complete % 8))) != 0
      complete += 1
    end
    # Never expose the total size before aria2 exits successfully. Homebrew's
    # resume logic can otherwise mistake a full-size partial for completion.
    [[complete * piece_length, total].min, total - 1].min
  end

  def self.mirror(workdir, destination)
    data = File.join(workdir, 'data')
    control = File.join(workdir, 'data.aria2')
    return if File.symlink?(data) || File.symlink?(control) || File.symlink?(destination)
    return unless File.file?(data) && File.file?(control)
    return unless File.size(control) <= MAX_CONTROL_SIZE

    prefix = confirmed_prefix(File.binread(control))
    return if prefix.nil? || prefix <= 0 || File.size(data) < prefix
    return if File.exist?(destination) && !File.file?(destination)

    # Append actual bytes, never truncate/extend as a progress placeholder.
    # The aria2 invocation disables its disk cache so saved completed pieces
    # are already readable from the staging file.
    flags = File::WRONLY | File::CREAT
    flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
    File.open(destination, flags, 0o600) do |output|
      offset = output.stat.size
      return if offset >= prefix
      output.seek(offset)
      File.open(data, 'rb') do |input|
        input.seek(offset)
        IO.copy_stream(input, output, prefix - offset)
      end
    end
  rescue SystemCallError, IOError, ArgumentError
    # Progress is optional; aria2 still owns download completion and exit code.
    nil
  end

  def self.run(workdir, destination, command)
    pid = Process.spawn(*command)
    %w[INT TERM HUP].each do |signal|
      Signal.trap(signal) do
        begin
          Process.kill(signal, pid)
        rescue Errno::ESRCH
          nil
        end
      end
    end
    loop do
      result = Process.waitpid2(pid, Process::WNOHANG)
      if result
        status = result.last
        return status.exitstatus || 128 + status.termsig
      end
      mirror(workdir, destination)
      sleep 0.2
    end
  end
end

if $PROGRAM_NAME == __FILE__
  workdir, destination = ARGV.shift(2)
  abort 'contiguous-progress: missing aria2 command' if ARGV.empty?
  exit ContiguousProgress.run(workdir, destination, ARGV)
end
