#!/usr/bin/env ruby
# Compatibility lifecycle. All subprocess arguments are arrays, never shell code.
require "json"
require "digest"
require "fileutils"
require "open3"
require "tempfile"
require "shellwords"
require "rbconfig"

class HomebrewCompat
  AUTO_UPDATE_DIGESTS = %w[171d6d5c5da4bfe1c3db446fb3d135f2e366de59970386a1359277fe97a5cf2b].freeze
  BEGIN_RC = "# BEGIN brew-curl-aria2 wrapper v1\n".freeze
  END_RC = "# END brew-curl-aria2 wrapper v1\n".freeze
  ANCHOR = '  HOMEBREW_CURL="${HOMEBREW_SELECTED_TOOL:-/usr/bin/false}"' + "\n"

  def initialize(prefix, shim)
    @prefix, @shim = File.expand_path(prefix), File.expand_path(shim)
    @lib = File.dirname(File.expand_path(__FILE__))
    @control = File.expand_path("../bin/brew-curl-aria2", @lib)
    @config = File.join(ENV["XDG_CONFIG_HOME"] || Dir.home, "homebrew")
    @config = File.join(Dir.home, ".homebrew") unless ENV["XDG_CONFIG_HOME"]
    @state_path = File.join(@config, "brew-curl-aria2.json")
    @env_path = File.join(@config, "brew.env")
    @state = File.file?(@state_path) ? JSON.parse(File.read(@state_path)) : {}
    @brew = @state["brew"] || File.join(@prefix, "bin/brew")
    @repo = @state["repository"]
  end

  def capture(*args)
    environment = { "BREW_CURL_ARIA2_WRAPPER_ACTIVE" => "1" }
    # A diagnostic `brew ruby` must not persistently enable developer mode.
    environment["HOMEBREW_DEVELOPER"] = "1" if args[1] == "ruby" && !ENV.key?("HOMEBREW_DEVELOPER")
    output, status = Open3.capture2(environment, *args)
    raise "command failed: #{args.first}" unless status.success?
    output.strip
  end

  def repository
    @repo ||= capture(@brew, "--repository")
    raise "invalid Homebrew repository" unless File.directory?(File.join(@repo, "Library/Homebrew"))
    @repo = File.realpath(@repo)
  end

  def locked
    base = ENV["XDG_CACHE_HOME"] || File.join(Dir.home, "Library/Caches")
    dir = File.join(base, "brew-curl-aria2")
    FileUtils.mkdir_p(dir, :mode => 0700)
    path = File.join(dir, Digest::SHA256.hexdigest(repository) + ".lock")
    raise "unsafe lock path" if File.symlink?(path)
    File.open(path, File::RDWR | File::CREAT, 0600) do |lock|
      lock.flock(File::LOCK_EX)
      # Reload state after waiting: disable may have happened in another terminal.
      @state = File.file?(@state_path) ? JSON.parse(File.read(@state_path)) : {}
      yield
    end
  end

  def atomic_write(path, text, mode = nil)
    raise "refusing symlink: #{path}" if File.symlink?(path)
    FileUtils.mkdir_p(File.dirname(path), :mode => 0700)
    permissions = mode || (File.exist?(path) ? File.stat(path).mode & 0777 : 0600)
    Tempfile.create([".aria2-", ".tmp"], File.dirname(path)) do |tmp|
      tmp.write(text); tmp.flush; tmp.fsync; tmp.chmod(permissions)
      yield tmp.path if block_given?
      File.rename(tmp.path, path)
    end
  end

  def patch(remove = false)
    path = File.join(repository, "Library/Homebrew/utils/curl.sh")
    original = File.read(path)
    block = File.read(File.join(@lib, "curl-selection.sh"))
    count = original.scan(/# BEGIN brew-curl-aria2 selection/).size
    if count > 0
      raise "unrecognized or modified aria2 patch; leaving Homebrew unchanged" unless count == 1 && original.include?(block)
      return :applied unless remove
      modified = original.sub(block, "")
    else
      return :absent if remove
      function = original[/^setup_curl\(\) \{\n.*?^\}\n/m]
      raise "unsupported setup_curl; leaving Homebrew unchanged" unless
        function && function.include?(ANCHOR) && original.scan(/^setup_curl\(\) \{/).size == 1 && original.scan(ANCHOR).size == 1 &&
        original.include?('  select_tool curl "${HOMEBREW_MINIMUM_CURL_VERSION}"') &&
        original.include?('HOMEBREW_CURL_VERSION_PATH="${HOMEBREW_CURL}"')
      modified = original.sub(ANCHOR, block + ANCHOR)
    end
    atomic_write(path, modified) do |temporary|
      raise "patched curl.sh failed syntax check" unless system("/bin/bash", "-n", temporary)
      raise "Homebrew changed during patching" unless File.read(path) == original
    end
    remove ? :removed : :applied
  end

  def repair
    patch
    true
  rescue StandardError => e
    warn "brew-curl-aria2: #{e.message}; using normal curl where the plugin cannot be selected."
    false
  end

  def rc_files
    zdir = ENV["ZDOTDIR"] || Dir.home
    bash_login = %w[.bash_profile .bash_login .profile].map { |name| File.join(Dir.home, name) }.find { |p| File.file?(p) }
    [File.join(zdir, ".zshrc"), File.join(Dir.home, ".bashrc"), bash_login || File.join(Dir.home, ".bash_profile")].uniq
  end

  def edit_rc(path, add)
    path = File.realpath(path) if File.symlink?(path)
    text = File.exist?(path) ? File.read(path) : ""
    if text.include?(BEGIN_RC) || text.include?(END_RC)
      raise "invalid managed block in #{path}" unless text.scan(BEGIN_RC).size == 1 && text.scan(END_RC).size == 1
      text = text.sub(/#{Regexp.escape(BEGIN_RC)}.*?#{Regexp.escape(END_RC)}/m, "")
    end
    if add
      text += "\n" unless text.empty? || text.end_with?("\n")
      text += BEGIN_RC
      text += "export BREW_CURL_ARIA2_REAL_BREW=#{Shellwords.escape(@brew)}\n"
      text += "export BREW_CURL_ARIA2_CONTROL=#{Shellwords.escape(@control)}\n"
      text += ". #{Shellwords.escape(File.join(@lib, 'brew-wrapper.sh'))}\n"
      text += END_RC
    end
    atomic_write(path, text, File.exist?(path) ? nil : 0644)
    path
  end

  def marker(add)
    text = File.file?(@env_path) ? File.read(@env_path) : ""
    text = text.lines.reject { |l| l.start_with?("HOMEBREW_BREW_CURL_ARIA2_SHIM=") }.join
    if add
      raise "shim path cannot contain a newline" if @shim.include?("\n")
      text += "\n" unless text.empty? || text.end_with?("\n")
      text += "HOMEBREW_BREW_CURL_ARIA2_SHIM=#{@shim}\n"
    end
    atomic_write(@env_path, text)
  end

  def enable
    repository
    locked do
      @state = { "enabled" => true, "brew" => @brew, "repository" => repository,
                 "shim" => @shim, "control" => @control, "rc_files" => rc_files }
      atomic_write(@state_path, JSON.pretty_generate(@state) + "\n")
      marker(true)
      repair
      @state["rc_files"] = rc_files.map { |p| edit_rc(p, true) }
      atomic_write(@state_path, JSON.pretty_generate(@state) + "\n")
    end
    puts "Homebrew compatibility enabled. Open a new terminal (or source your shell rc) to load the brew wrapper."
  end

  def disable
    return unless File.file?(@state_path)
    locked do
      @state["enabled"] = false
      atomic_write(@state_path, JSON.pretty_generate(@state) + "\n")
      marker(false)
      @state.fetch("rc_files", []).each { |path| edit_rc(path, false) }
      patch(true)
    end
  end

  def enabled?
    @state["enabled"] == true && File.file?(@env_path) &&
      File.read(@env_path).lines.any? { |l| l.chomp == "HOMEBREW_CURL_PATH=#{@state['shim']}" }
  end

  def runtime_env
    json = capture(@brew, "ruby", "-e", 'require "json"; puts JSON.generate(ENV.select { |k, _| k.start_with?("HOMEBREW_") })')
    values = JSON.parse(json)
    values.delete("HOMEBREW_DEVELOPER") unless ENV.key?("HOMEBREW_DEVELOPER")
    # `brew ruby` itself calls auto-update for a non-updating command and sets
    # this flag. It describes the probe, not the user's install/upgrade.
    values.delete("HOMEBREW_AUTO_UPDATE_CHECKED") unless ENV.key?("HOMEBREW_AUTO_UPDATE_CHECKED")
    values
  end

  def run_child(env, *args)
    pid = Process.spawn(env.merge("BREW_CURL_ARIA2_WRAPPER_ACTIVE" => "1"), *args)
    previous = {}
    %w[INT TERM HUP].each do |signal|
      previous[signal] = Signal.trap(signal) do
        begin Process.kill(signal, pid); rescue Errno::ESRCH; end
      end
    end
    begin
      _, status = Process.wait2(pid)
      status.exitstatus || 128 + status.termsig
    ensure
      previous.each { |signal, handler| Signal.trap(signal, handler) }
    end
  end

  def update(env, args)
    patch(true)
    begin
      run_child(env, @brew, *args)
    ensure
      repair if enabled?
    end
  end

  def decision(env, args)
    path = File.join(repository, "Library/Homebrew/utils/auto-update.sh")
    return nil unless File.file?(path) && AUTO_UPDATE_DIGESTS.include?(Digest::SHA256.file(path).hexdigest)
    env = env.merge("HOMEBREW_COMMAND" => args.first, "HOMEBREW_ARG_COUNT" => args.size.to_s)
    output, status = Open3.capture2(env, "/bin/bash", File.join(@lib, "auto-update-adapter.sh"), *args)
    raise "auto-update adapter failed" unless status.success?
    fields = output.split("\0", -1)
    raise "invalid auto-update decision" unless fields.size == 7 && %w[0 1].include?(fields[1])
    fields
  end

  def wrap(args)
    return run_child({}, @brew, *args) unless enabled?
    index = args.index { |arg| !arg.start_with?("-") }
    command = index && args[index]
    return run_child({}, @brew, *args) unless %w[install upgrade update up update-reset].include?(command)
    return run_child({}, @brew, *args) if args.any? { |a| %w[--help -h --version].include?(a) }
    # Leading global options are not silently rearranged into another command.
    if index != 0
      warn "brew-curl-aria2: leading global options bypass automatic repair; use brew COMMAND --options."
      return run_child({}, @brew, *args)
    end
    locked do
      return run_child({}, @brew, *args) unless enabled?
      if %w[update up update-reset].include?(command)
        return update({}, args)
      end
      begin
        env = runtime_env
        fields = decision(env, args)
      rescue StandardError => e
        warn "brew-curl-aria2: cannot coordinate this Homebrew version (#{e.message}); keeping native command behaviour."
        return update({}, args)
      end
      unless fields
        warn "brew-curl-aria2: unsupported Homebrew auto-update adapter; keeping native update behaviour. Run repair-homebrew after updates."
        return update({}, args)
      end
      if fields[1] == "1"
        update_env = env.merge("HOMEBREW_AUTO_UPDATING" => "1", "HOMEBREW_AUTO_UPDATE_CHECKED" => "1")
        %w[HOMEBREW_AUTO_UPDATE_TAP HOMEBREW_AUTO_UPDATE_SKIP_OUTDATED HOMEBREW_AUTO_UPDATE_CORE_TAP HOMEBREW_AUTO_UPDATE_CASK_TAP].each_with_index do |key, i|
          update_env[key] = fields[i + 2].empty? ? nil : fields[i + 2]
        end
        rc = update(update_env, ["update", "--auto-update"])
        return rc if rc >= 128
        warn "brew-curl-aria2: automatic update failed (#{rc}); continuing with available Homebrew data." unless rc == 0
      else
        repair
      end
      # Only pass the handoff flag, not the pre-update snapshot of internal paths.
      run_child({ "HOMEBREW_AUTO_UPDATE_CHECKED" => fields[0].empty? ? nil : fields[0] }, @brew, *args)
    end
  end

  def status
    puts "  Enable intent   : #{@state['enabled'] == true ? 'enabled' : 'disabled'}"
    puts "  Shell wrapper   : #{ENV['BREW_CURL_ARIA2_WRAPPER_LOADED'] == '1' ? 'loaded' : 'not observed in this shell'}"
    path = File.join(repository, "Library/Homebrew/utils/curl.sh")
    text = File.read(path)
    puts "  Homebrew patch  : #{text.include?(File.read(File.join(@lib, 'curl-selection.sh'))) ? 'applied' : 'missing/unsupported'}"
    selected = capture(@brew, "ruby", "-e", 'require "utils/curl"; puts Utils::Curl.curl_path')
    puts "  Selected curl   : #{selected}"
    puts "  aria2 selected  : #{selected == @shim ? 'yes' : 'no'}"
  end

  def test(url)
    env = runtime_env
    selected = capture(@brew, "ruby", "-e", 'require "utils/curl"; puts Utils::Curl.curl_path')
    raise "Homebrew selected #{selected}, not #{@shim}" unless selected == @shim
    Dir.mktmpdir("brew-aria2-test-") do |dir|
      # The SHA is checked against an independent, real curl download.
      curl = File.executable?(File.join(@prefix, "opt/curl/bin/curl")) ? File.join(@prefix, "opt/curl/bin/curl") : "/usr/bin/curl"
      reference = File.join(dir, "reference")
      raise "reference download failed" unless run_child({}, curl, "--fail", "--location", "--silent", "--show-error", "--output", reference, url) == 0
      sha = Digest::SHA256.file(reference).hexdigest
      code = 'require "resource"; r=Resource.new("aria2-selftest"); r.url ENV.fetch("HOMEBREW_BREW_CURL_ARIA2_TEST_URL"); r.version "1.0"; r.sha256 ENV.fetch("HOMEBREW_BREW_CURL_ARIA2_TEST_SHA"); r.fetch; abort "checksum mismatch" unless Digest::SHA256.file(r.cached_download).hexdigest == ENV.fetch("HOMEBREW_BREW_CURL_ARIA2_TEST_SHA")'
      log = File.join(dir, "backend.log")
      rc = run_child({ "HOMEBREW_CACHE" => dir, "HOMEBREW_NO_AUTO_UPDATE" => "1", "HOMEBREW_DEVELOPER" => "1",
                       "HOMEBREW_BREW_CURL_ARIA2_LOG" => log, "HOMEBREW_BREW_CURL_ARIA2_TEST_URL" => url,
                       "HOMEBREW_BREW_CURL_ARIA2_TEST_SHA" => sha }, @brew, "ruby", "-e", code)
      raise "real brew download did not use aria2 or checksum failed" unless rc == 0 && File.file?(log) && File.read(log).include?("backend=aria2c")
      puts "PASS: real Homebrew Resource download, aria2 invocation and SHA-256 #{sha}"
    end
  end

  def dispatch(action, args)
    case action
    when "enable" then enable
    when "disable" then disable
    when "repair-homebrew" then locked { raise "plugin is disabled; run enable first" unless enabled?; return repair ? 0 : 1 }
    when "status" then status
    when "wrap" then return wrap(args)
    when "test" then locked { test(args.fetch(0)) }
    else raise "unknown compatibility command"
    end
    0
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    action, prefix, shim = ARGV.shift(3)
    exit HomebrewCompat.new(prefix, shim).dispatch(action, ARGV)
  rescue StandardError => e
    warn "brew-curl-aria2: #{e.message}"
    exit 1
  end
end
