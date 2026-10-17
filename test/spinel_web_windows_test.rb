# frozen_string_literal: true

# Run on native Windows with the compiled binary and Devkit gcc on PATH.
unless RUBY_PLATFORM.match?(/mingw|mswin/) && ENV["TYCHO_PROTO_TEST_BINARY"]
  puts "spinel_web_windows_test: skipped (requires native Windows binary)"
  exit
end

require "tmpdir"
require "fileutils"
require "socket"
require "net/http"
require "json"
require "timeout"

def assert(value, message)
  raise message unless value
end

def request(method = "GET", path = "/api/run", prompt = nil, token: @token, origin: @origin)
  message = (method == "POST" ? Net::HTTP::Post : Net::HTTP::Get).new(path)
  message["Authorization"] = "Bearer #{token}" if token
  message["Origin"] = origin
  message["Content-Type"] = "application/json"
  message.body = JSON.generate({ "prompt" => prompt }) if method == "POST"
  Net::HTTP.start("127.0.0.1", @port, nil) { |http| http.request(message) }
end

def wait_state(status)
  Timeout.timeout(12) do
    loop do
      state = JSON.parse(request.body)
      return state if state["status"] == status
      sleep 0.1
    end
  end
end

def launch
  environment = { "TYCHO_PROTO_STATE" => @state, "TYCHO_PROTO_WORKSPACE" => @workspace,
                  "TYCHO_PROTO_EXECUTABLE" => @fixture, "TYCHO_PROTO_FIXTURE" => "1",
                  "TYCHO_PROTO_PORT" => @port.to_s, "TYCHO_REMOTE_TOKEN" => "private-test-sentinel",
                  "PATH" => ENV.fetch("SystemRoot") + "/System32" }
  @pid = Process.spawn(environment, [@binary, @binary], out: @log, err: [:child, :out])
  Timeout.timeout(10) do
    loop do
      begin
        TCPSocket.new("127.0.0.1", @port).close
        break
      rescue Errno::ECONNREFUSED
        raise File.read(@log) if Process.waitpid(@pid, Process::WNOHANG)
        sleep 0.1
      end
    end
  end
  @token = File.read(File.join(@state, "access-token"))
end

def shutdown
  Process.kill("KILL", @pid)
  Process.waitpid(@pid)
  @pid = nil
end

Dir.mktmpdir("tycho-windows-") do |directory|
  begin
    @workspace = File.join(directory, "workspace")
    FileUtils.mkdir_p(@workspace)
    @state = File.join(directory, "private-state")
    @log = File.join(directory, "server.log")
    @fixture = File.join(directory, "fixture.exe")
    assert(system("gcc", "-O2", "-municode", File.join(__dir__, "support/spinel_windows_fixture.c"), "-o", @fixture), "Fixture compile failed")
    relocated = File.join(directory, "relocated 日本語")
    FileUtils.mkdir_p(relocated)
    @binary = File.join(relocated, "tycho prototype.exe")
    FileUtils.cp(ENV.fetch("TYCHO_PROTO_TEST_BINARY"), @binary)
    probe = TCPServer.new("127.0.0.1", 0)
    @port = probe.addr[1]
    probe.close
    @origin = "http://127.0.0.1:#{@port}"
    launch
    assert(request(token: nil).code == "401", "Unauthenticated API accepted")
    assert(request("GET", "/").body.include?("Tycho"), "Missing embedded page")
    assert(request("POST", "/api/run", "no", origin: "https://evil.example").code == "403", "Foreign origin accepted")
    prompt = "日本語 \"quoted\" & echo injected > injected.txt \\ trailing\\"
    assert(request("POST", "/api/run", prompt).code == "200", "Run rejected")
    state = wait_state("succeeded")
    assert(state["result"] == prompt, "Argument or UTF-8 corruption: #{state["result"].inspect} != #{prompt.inspect}")
    assert(!File.exist?(File.join(@workspace, "injected.txt")), "Shell injection")
    assert(state["output"].include?("server-token=unset") && state["output"].include?("prototype-env=unset"), "Environment leak")
    assert(state["output"].include?("stderr-visible"), "Stderr missing")
    request("POST", "/api/run", "FAIL")
    assert(wait_state("failed")["exit_code"] == "7", "Exit status lost")
    %w[HOLD LEADER_EXITS].each do |prompt_text|
      pid_file = File.join(@workspace, "child.pid")
      File.delete(pid_file) if File.exist?(pid_file)
      request("POST", "/api/run", prompt_text)
      Timeout.timeout(10) { sleep 0.1 until File.exist?(pid_file) }
      child = Integer(File.read(pid_file))
      if prompt_text == "HOLD"
        assert(request("POST", "/api/run", "overlap").code == "409", "Overlapping run accepted")
        request("POST", "/api/stop")
        wait_state("stopped")
      else
        wait_state("succeeded")
      end
      sleep 0.2
      alive = system("powershell.exe", "-NoProfile", "-Command", "if (Get-Process -Id #{child} -ErrorAction SilentlyContinue) { exit 1 }", out: File::NULL)
      assert(alive, "Descendant survived #{prompt_text}")
    end
    shutdown
    launch
    assert(JSON.parse(request.body)["status"] == "succeeded", "Saved state not restored")
    shutdown
    # Fail closed when an existing state file grants read access to Everyone.
    token_path = File.join(@state, "access-token")
    assert(system("icacls.exe", token_path, "/grant", "*S-1-1-0:R", out: File::NULL), "ACL fixture failed")
    failed = false
    begin
      launch
    rescue RuntimeError => error
      failed = error.message.include?("Unsafe Windows state file")
      @pid = nil
    end
    assert(failed, "Permissive token ACL accepted")
    puts "spinel_web_windows_test: ok (native HTTP, auth, argv, environment, exit, job tree, restore, ACL, relocated binary)"
  ensure
    shutdown if @pid
  end
end
