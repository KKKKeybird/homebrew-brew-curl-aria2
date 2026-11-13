#!/usr/bin/env ruby
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"
require "json"
require_relative "../libexec/homebrew-compat"

class CompatibilityTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def setup
    @tmp = Dir.mktmpdir("aria2-compat-")
    @prefix = File.join(@tmp, "brew prefix")
    @utils = File.join(@prefix, "Library/Homebrew/utils")
    @home = File.join(@tmp, "home")
    @config = File.join(@tmp, "config/homebrew")
    FileUtils.mkdir_p([@utils, @home, @config, File.join(@prefix, "bin"), File.join(@prefix, ".git")])
    %w[curl tool auto-update].each do |name|
      FileUtils.cp(File.join(__dir__, "fixtures/homebrew-#{name}.sh"), File.join(@utils, "#{name}.sh"))
    end
    @curl = File.join(@utils, "curl.sh")
    @env = ENV.to_h.reject { |key, _| key.start_with?("HOMEBREW_", "BREW_CURL_ARIA2_") }
    @env.merge!("HOME" => @home, "XDG_CONFIG_HOME" => File.dirname(@config),
                "XDG_CACHE_HOME" => File.join(@tmp, "cache"), "HOMEBREW_PREFIX" => @prefix,
                "PATH" => "#{@prefix}/bin:/usr/bin:/bin:/usr/sbin:/sbin", "TEST_PREFIX" => @prefix)
    File.write(File.join(@prefix, "bin/aria2c"), "#!/bin/bash\nexit 0\n")
    File.chmod(0755, File.join(@prefix, "bin/aria2c"))
    @brew = File.join(@prefix, "bin/brew")
    File.write(@brew, <<~'RUBY')
      #!/usr/bin/env ruby
      require "json"
      prefix = ENV.fetch("TEST_PREFIX")
      config = File.join(ENV.fetch("XDG_CONFIG_HOME"), "homebrew/brew.env")
      if File.file?(config)
        File.readlines(config).each { |l| k,v=l.chomp.split("=",2); ENV[k]=v if k && v && k.start_with?("HOMEBREW_") }
      end
      env = ENV.to_h.merge("HOMEBREW_REPOSITORY" => prefix, "HOMEBREW_PREFIX" => prefix,
        "HOMEBREW_LIBRARY" => "#{prefix}/Library", "HOMEBREW_CORE_REPOSITORY" => "#{prefix}/Library/Taps/homebrew/homebrew-core",
        "HOMEBREW_CASK_REPOSITORY" => "#{prefix}/Library/Taps/homebrew/homebrew-cask")
      patched = File.read("#{prefix}/Library/Homebrew/utils/curl.sh").include?("BEGIN brew-curl-aria2 selection")
      case ARGV.first
      when "--repository" then puts prefix
      when "ruby"
        if ARGV.last.include?("JSON.generate")
          env["HOMEBREW_AUTO_UPDATE_CHECKED"] = "1" unless ENV["HOMEBREW_NO_AUTO_UPDATE"]
          puts JSON.generate(env.select { |k,_| k.start_with?("HOMEBREW_") })
        else
          puts(patched && !ENV["HOMEBREW_FORCE_BREWED_CURL"] ? ENV["HOMEBREW_CURL_PATH"] : "/usr/bin/curl")
        end
      else
        record = {"args"=>ARGV,"patch"=>patched,"checked"=>ENV["HOMEBREW_AUTO_UPDATE_CHECKED"],
                  "tap"=>ENV["HOMEBREW_AUTO_UPDATE_TAP"],"skip"=>ENV["HOMEBREW_AUTO_UPDATE_SKIP_OUTDATED"],"event"=>"start"}
        File.open("#{prefix}/events", "a") { |f| f.puts JSON.generate(record) }
        if %w[update up update-reset].include?(ARGV.first)
          text = File.read("#{prefix}/Library/Homebrew/utils/curl.sh")
          File.write("#{prefix}/Library/Homebrew/utils/curl.sh", text + "\n# upstream addition\n")
          File.write("#{prefix}/.git/FETCH_HEAD", "updated")
          if ENV["TEST_UPSTREAM_DRIFT"]
            path="#{prefix}/Library/Homebrew/utils/curl.sh"
            File.write(path, File.read(path).sub("setup_curl()", "new_setup_curl()"))
          end
          exit ENV.fetch("TEST_UPDATE_RC", "0").to_i
        end
        sleep ENV.fetch("TEST_INSTALL_SLEEP", "0").to_f
        File.open("#{prefix}/events", "a") { |f| f.puts JSON.generate(record.merge("event"=>"end")) }
        exit ENV.fetch("TEST_INSTALL_RC", "0").to_i
      end
    RUBY
    File.chmod(0755, @brew)
    File.write(File.join(@config, "brew.env"), "OTHER_SETTING=keep\n")
    File.write(File.join(@home, ".zshrc"), "# user config\n")
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def ctl(*args)
    env = args.last.is_a?(Hash) ? args.pop : {}
    out, err, status = Open3.capture3(@env.merge(env), File.join(ROOT, "bin/brew-curl-aria2"), *args, :unsetenv_others => true)
    [out, err, status.exitstatus]
  end

  def enable
    out, err, rc = ctl("enable")
    assert_equal 0, rc, out + err
  end

  def wrap(*args)
    ctl("wrap", *args)
  end

  def events
    path = File.join(@prefix, "events")
    File.file?(path) ? File.readlines(path).map { |l| JSON.parse(l) } : []
  end

  def test_idempotence_and_disable_preserve_local_changes
    enable; enable
    assert_equal 1, File.read(@curl).scan("BEGIN brew-curl-aria2 selection").size
    assert_equal 1, File.read(File.join(@home, ".zshrc")).scan("BEGIN brew-curl-aria2 wrapper").size
    File.open(@curl,"a") { |f| f.puts "# unrelated local edit" }
    assert_equal 0, ctl("disable")[2]
    assert_includes File.read(@curl), "# unrelated local edit"
    refute_includes File.read(@curl), "BEGIN brew-curl-aria2"
    assert_equal "# user config\n", File.read(File.join(@home, ".zshrc"))
    assert_includes File.read(File.join(@config,"brew.env")), "OTHER_SETTING=keep"
    refute_includes File.read(File.join(@config,"brew.env")), "HOMEBREW_CURL_PATH="
    assert_equal 0, wrap("install", "wget")[2]
    refute events.last["patch"]
  end

  def test_explicit_update_reapplies_before_next_install
    enable
    assert_equal 0, wrap("update")[2]
    refute events.first["patch"], "patch must be removed before updating"
    assert_includes File.read(@curl), "# upstream addition"
    assert_includes File.read(@curl), "BEGIN brew-curl-aria2"
    assert_equal 0, wrap("install", "wget")[2]
    assert events.last["patch"]
    assert_equal 1, events.count { |e| e["args"].first == "update" }
  end

  def test_auto_update_then_install_and_third_party_tap
    enable
    assert_equal 0, wrap("install", "someone/tap/example")[2]
    update, install = events.select { |e| e["event"] == "start" }
    assert_equal ["update", "--auto-update"], update["args"]
    assert_equal "1", update["tap"]
    refute update["patch"]
    assert install["patch"]
    assert_equal "1", install["checked"]
    assert_equal ["install", "someone/tap/example"], install["args"]
  end

  def test_no_update_and_user_disabled_update
    enable
    File.write(File.join(@prefix, ".git/FETCH_HEAD"), "fresh")
    assert_equal 0, wrap("upgrade", "wget")[2]
    assert_equal 0, wrap("install", "wget", "HOMEBREW_NO_AUTO_UPDATE" => "1")[2]
    assert events.all? { |e| e["args"].first != "update" }
    assert events.all? { |e| e["patch"] }
  end

  def test_failure_status_and_update_reset
    enable
    out, err, rc = wrap("update", "TEST_UPDATE_RC" => "17")
    assert_equal 17, rc, out + err
    assert_includes File.read(@curl), "BEGIN brew-curl-aria2"
    FileUtils.rm_f(File.join(@prefix, ".git/FETCH_HEAD"))
    _, err, rc = wrap("upgrade", "TEST_UPDATE_RC" => "17", "TEST_INSTALL_RC" => "23")
    assert_equal 23, rc
    assert_includes err, "automatic update failed (17)"
    assert_equal 0, wrap("update-reset")[2]
    assert_includes File.read(@curl), "BEGIN brew-curl-aria2"
  end

  def test_source_drift_falls_back_without_rewriting
    enable
    _, err, rc = wrap("update", "TEST_UPSTREAM_DRIFT" => "1")
    assert_equal 0, rc
    assert_includes err, "unsupported setup_curl"
    refute_includes File.read(@curl), "BEGIN brew-curl-aria2"
    assert_includes File.read(@curl), "new_setup_curl()"
    assert_equal 0, wrap("install", "wget")[2]
    refute events.last["patch"]
  end

  def test_unsupported_adapter_uses_native_command_then_repairs
    enable
    File.open(File.join(@utils,"auto-update.sh"), "a") { |f| f.puts "# changed" }
    _, err, rc = wrap("install", "wget")
    assert_equal 0, rc
    assert_includes err, "unsupported Homebrew auto-update adapter"
    refute events.last["patch"]
    assert_includes File.read(@curl), "BEGIN brew-curl-aria2"
  end

  def test_upstream_update_intervals
    enable
    head = File.join(@prefix, ".git/FETCH_HEAD")
    File.write(head,"fetched"); old=Time.now-600; File.utime(old,old,head)
    assert_equal 0, wrap("install", "wget")[2]
    refute events.any? { |e| e["args"].first == "update" }
    assert_equal 0, wrap("install", "someone/tap/example")[2]
    assert events.any? { |e| e["args"].first == "update" }
  end

  def test_shell_wrappers_keep_arguments_and_disabled_passthrough
    enable
    %w[/bin/bash /bin/zsh].each do |shell|
      next unless File.executable?(shell)
      rcfile=File.join(@home, shell.end_with?("zsh") ? ".zshrc" : ".bashrc")
      # Avoid startup files outside the fixture; source the managed loader explicitly.
      script='source "$1"; brew install "name with spaces" --force'
      _, err, status=Open3.capture3(@env.merge("HOMEBREW_NO_AUTO_UPDATE"=>"1"),shell,"-c",script,"shell",rcfile,:unsetenv_others=>true)
      assert status.success?, err
      assert_equal ["install","name with spaces","--force"], events.last["args"]
      # Queries must bypass Ruby/state parsing even if the state is damaged.
      state=File.join(@config,"brew-curl-aria2.json")
      saved=File.read(state)
      File.write(state,"invalid json")
      _,err,status=Open3.capture3(@env,shell,"-c",'source "$1"; brew --version',"shell",rcfile,:unsetenv_others=>true)
      assert status.success?,err
      File.write(state,saved)
    end
  end

  def test_concurrent_wrapped_commands_are_serial
    enable
    env=@env.merge("HOMEBREW_NO_AUTO_UPDATE"=>"1","TEST_INSTALL_SLEEP"=>"0.3")
    pids=2.times.map { Process.spawn(env,File.join(ROOT,"bin/brew-curl-aria2"),"wrap","install","wget",:out=>File::NULL,:err=>File::NULL,:unsetenv_others=>true) }
    pids.each { |pid| _,s=Process.wait2(pid); assert s.success? }
    assert_equal %w[start end start end], events.map { |e| e["event"] }
  end

  def test_interrupted_child_releases_lock_and_next_call_repairs
    enable
    File.write(File.join(@prefix, ".git/FETCH_HEAD"), "fresh")
    pid=Process.spawn(@env.merge("TEST_INSTALL_SLEEP"=>"30"),File.join(ROOT,"bin/brew-curl-aria2"),"wrap","install","wget",:out=>File::NULL,:err=>File::NULL,:unsetenv_others=>true)
    deadline=Time.now+5
    sleep 0.02 until events.any? || Time.now>deadline
    assert events.any?, "install did not start"
    Process.kill("TERM",pid)
    _,s=Process.wait2(pid)
    assert_equal 143,s.exitstatus
    assert_equal 0,wrap("install","wget")[2]
    assert events.last["patch"]
  ensure
    begin Process.kill("KILL",pid) if pid; rescue Errno::ESRCH; end
  end

  def test_actual_selector_precedence_version_validation_and_system_state
    enable
    brewed = File.join(@prefix, "opt/curl/bin/curl")
    custom = File.join(@tmp, "custom curl")
    FileUtils.mkdir_p(File.dirname(brewed))
    File.write(brewed, "#!/bin/bash\necho 'curl 99.0.0'\n")
    File.write(custom, "#!/bin/bash\necho 'curl 8.0.0'\n")
    File.chmod(0755, brewed, custom)
    script = <<~'BASH'
      numeric() { local a b c; IFS=. read -r a b c <<< "$1"; printf '%d%03d%03d\n' "${a:-0}" "${b:-0}" "${c:-0}"; }
      source "$HOMEBREW_LIBRARY/Homebrew/utils/tool.sh"
      source "$HOMEBREW_LIBRARY/Homebrew/utils/curl.sh"
      setup_curl
      printf '%s\n' "$HOMEBREW_CURL" "$HOMEBREW_CURL_VERSION" "$HOMEBREW_CURL_VERSION_PATH" "$HOMEBREW_SYSTEM_TOOL_USABLE"
    BASH
    env = @env.merge("HOMEBREW_LIBRARY"=>File.join(@prefix,"Library"), "HOMEBREW_CACHE"=>File.join(@tmp,"selection-cache"),
                     "HOMEBREW_CURL_PATH"=>custom, "HOMEBREW_BREW_CURL_ARIA2_SHIM"=>custom)
    select = lambda do |overrides|
      out,err,status=Open3.capture3(env.merge(overrides),"/bin/bash","-c",script,:unsetenv_others=>true)
      assert status.success?,err
      out.lines.map(&:strip)
    end
    assert_equal [custom,"8.0.0",custom,"1"],select.call({})
    assert_equal brewed,select.call("HOMEBREW_FORCE_BREWED_CURL"=>"1").first
    assert_equal brewed,select.call("HOMEBREW_BREW_CURL_ARIA2_SHIM"=>"").first
    File.write(custom,"#!/bin/bash\necho 'curl 7.0.0'\n")
    assert_equal brewed,select.call({}).first
    File.write(custom,"#!/bin/bash\necho 'curl 99.0.0'\nexit 1\n")
    assert_equal brewed,select.call({}).first
  end

  def test_manual_repair_and_modified_patch_protection
    assert_equal 1,ctl("repair-homebrew")[2]
    enable
    block=File.read(File.join(ROOT,"libexec/curl-selection.sh"))
    File.write(@curl,File.read(@curl).sub(block,""))
    assert_equal 0,ctl("repair-homebrew")[2]
    assert_equal 1,File.read(@curl).scan("BEGIN brew-curl-aria2 selection").size
    File.write(@curl,File.read(@curl).sub("# Only override the default", "# User changed: only override the default"))
    before=File.read(@curl)
    _,err,rc=ctl("repair-homebrew")
    assert_equal 1,rc
    assert_includes err,"unrecognized or modified aria2 patch"
    assert_equal before,File.read(@curl)
  end
end
