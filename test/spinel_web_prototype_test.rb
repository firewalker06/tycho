# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "socket"
require "net/http"
require "json"
require "timeout"
require "rbconfig"

class SpinelWebPrototypeTest
  ROOT = File.expand_path("..", __dir__)

  def assert(condition, message = "Assertion failed")
    raise message unless condition
  end

  def assert_equal(expected, actual)
    assert(expected == actual, "Expected #{expected.inspect}, got #{actual.inspect}")
  end

  def assert_includes(text, value)
    assert(text.include?(value), "Missing #{value.inspect}")
  end

  def refute(condition)
    assert(!condition)
  end

  def refute_includes(text, value)
    refute(text.include?(value))
  end

  def assert_match(pattern, text)
    assert(pattern.match?(text), "Pattern did not match")
  end

  def flunk(message)
    raise message
  end

  def setup
    @directory = Dir.mktmpdir("tycho-spinel-test-")
    @state = File.join(@directory, "state")
    @workspace = File.join(@directory, "workspace")
    FileUtils.mkdir_p(@workspace)
    @fixture = File.join(@directory, "fixture")
    File.write(@fixture, <<~'SH')
      #!/bin/sh
      printf 'fixture-start\n'
      printf 'server-token=%s\n' "${TYCHO_REMOTE_TOKEN-unset}"
      printf 'prototype-env=%s\n' "${TYCHO_PROTO_STATE-unset}"
      printf 'stderr-visible\n' >&2
      if [ "$1" = HOLD ]; then
        trap '' TERM
        sleep 120 &
        echo $! > child.pid
        wait
      fi
      if [ "$1" = LEADER_EXITS ]; then
        /bin/sh -c 'trap "" TERM; sleep 120' &
        echo $! > child.pid
        sleep 120
      fi
      printf '%s' "$1" > "$2"
      printf 'fixture-complete\n'
      if [ "$1" = FAIL ]; then exit 7; fi
    SH
    File.chmod(0o700, @fixture)
    probe = TCPServer.new("127.0.0.1", 0)
    @port = probe.addr[1]
    probe.close
    @origin = "http://127.0.0.1:#{@port}"
    @remote_origin = "https://prototype.example.ts.net:9443"
    if ENV["TYCHO_PROTO_TEST_BINARY"]
      @command = [ENV.fetch("TYCHO_PROTO_TEST_BINARY")]
    else
      build = File.join(@directory, "build")
      assert system(RbConfig.ruby, File.join(ROOT, "prototypes/spinel_web/build.rb"), build, out: File::NULL)
      @command = [RbConfig.ruby, File.join(build, "prototype.rb")]
    end
    launch
  end

  def launch
    environment = { "TYCHO_PROTO_STATE" => @state, "TYCHO_PROTO_WORKSPACE" => @workspace,
                    "TYCHO_PROTO_EXECUTABLE" => @fixture, "TYCHO_PROTO_FIXTURE" => "1",
                    "TYCHO_PROTO_PORT" => @port.to_s, "TYCHO_PROTO_ORIGIN" => @remote_origin,
                    "TYCHO_REMOTE_TOKEN" => "server-secret-test-sentinel" }
    environment["PATH"] = "/usr/bin:/bin" if ENV["TYCHO_PROTO_TEST_BINARY"]
    @pid = Process.spawn(environment, [@command[0], @command[0]], *@command.drop(1),
                         out: File.join(@directory, "server.log"), err: [:child, :out])
    Timeout.timeout(15) do
      loop do
        begin
          TCPSocket.new("127.0.0.1", @port).close
          break
        rescue Errno::ECONNREFUSED
          if Process.waitpid(@pid, Process::WNOHANG)
            @pid = nil
            flunk File.read(File.join(@directory, "server.log"))
          end
          sleep 0.05
        end
      end
    end
    @token = File.read(File.join(@state, "access-token"))
  end

  def shutdown
    return unless @pid

    Process.kill("TERM", @pid)
    Timeout.timeout(8) { Process.waitpid(@pid) }
    @pid = nil
  rescue Errno::ESRCH, Errno::ECHILD
    @pid = nil
  end

  def teardown
    shutdown
    FileUtils.remove_entry(@directory) if @directory
  end

  def request(method = "GET", path = "/api/run", data = nil, token: @token, origin: @origin, host: nil)
    klass = method == "POST" ? Net::HTTP::Post : Net::HTTP::Get
    message = klass.new(path)
    message["Authorization"] = "Bearer #{token}" if token
    message["Origin"] = origin if origin
    message["Host"] = host if host
    message["Content-Type"] = "application/json"
    message.body = JSON.generate(data) if data
    Net::HTTP.start("127.0.0.1", @port, nil, nil) { |http| http.request(message) }
  end

  def wait_for(status)
    Timeout.timeout(8) do
      loop do
        data = JSON.parse(request.body)
        return data if data["status"] == status
        sleep 0.05
      end
    end
  end

  def test_auth_origin_and_host_boundaries
    assert_equal "401", request(token: nil).code
    assert_equal "401", request(token: "0" * 64).code
    assert_equal "403", request("POST", "/api/run", { prompt: "hello" }, origin: "https://untrusted.example").code
    assert_equal "403", request("POST", "/api/run", { prompt: "hello" }, origin: nil).code
    assert_equal "400", request(host: "untrusted.example").code
    assert_equal "idle", JSON.parse(request.body)["status"]
    assert_equal "200", request(host: "prototype.example.ts.net:9443").code
    assert_equal "200", request("POST", "/api/run", { prompt: "hello" }, origin: @remote_origin, host: "prototype.example.ts.net:9443").code
    wait_for("succeeded")
  end

  def test_run_output_literal_arguments_and_restart
    prompt = 'hello 日本語 <script>alert(1)</script> $(touch INJECTED)'
    assert_equal "200", request("POST", "/api/run", { prompt: prompt }).code
    data = wait_for("succeeded")
    assert_equal prompt, data["result"]
    assert_includes data["output"], "server-token=unset"
    assert_includes data["output"], "prototype-env=unset"
    assert_includes data["output"], "stderr-visible"
    refute File.exist?(File.join(@workspace, "INJECTED"))
    assert_equal 0, File.stat(File.join(@state, "access-token")).mode & 0o077
    assert_equal 0, File.stat(File.join(@state, "run.json")).mode & 0o077
    shutdown
    launch
    restored = JSON.parse(request.body)
    assert_equal "succeeded", restored["status"]
    assert_equal prompt, restored["result"]
    refute_includes File.read(File.join(@directory, "server.log")), @token
  end

  def test_stop_kills_process_group_and_rejects_overlap
    assert_equal "200", request("POST", "/api/run", { prompt: "HOLD" }).code
    Timeout.timeout(5) { sleep 0.02 until File.exist?(File.join(@workspace, "child.pid")) }
    child = File.read(File.join(@workspace, "child.pid")).to_i
    assert_equal "409", request("POST", "/api/run", { prompt: "second" }).code
    assert_equal "200", request("POST", "/api/stop", {}).code
    wait_for("stopped")
    Timeout.timeout(5) do
      loop do
        begin
          Process.kill(0, child)
          sleep 0.05
        rescue Errno::ESRCH
          break
        end
      end
    end
  end

  def test_stop_kills_descendant_when_leader_exits_on_term
    request("POST", "/api/run", { prompt: "LEADER_EXITS" })
    Timeout.timeout(5) { sleep 0.02 until File.exist?(File.join(@workspace, "child.pid")) }
    child = File.read(File.join(@workspace, "child.pid")).to_i
    sleep 0.1
    assert_equal "200", request("POST", "/api/stop", {}).code
    wait_for("stopped")
    Timeout.timeout(5) do
      loop do
        begin
          Process.kill(0, child)
          sleep 0.05
        rescue Errno::ESRCH
          break
        end
      end
    end
  end

  def test_failure_invalid_input_and_static_assets
    assert_equal "400", request("POST", "/api/run", { prompt: "" }).code
    assert_equal "400", request("POST", "/api/run", { prompt: "x" * 4001 }).code
    assert_equal "400", request("POST", "/api/run", { prompt: 42 }).code
    assert_equal "200", request("POST", "/api/run", { prompt: "FAIL" }).code
    assert_equal "7", wait_for("failed")["exit_code"]
    %w[/ /app.js /app.css].each do |path|
      response = request("GET", path, token: nil)
      assert_equal "200", response.code
      assert response.body.bytesize > 100
      assert_includes response["Content-Security-Policy"], "frame-ancestors 'none'"
      refute_includes response.body, @token
    end
    assert_equal "404", request("GET", "/../access-token").code
  end

  def test_ambiguous_request_framing_is_rejected
    ["Content-Length: 2\r\nContent-Length: 2", "Transfer-Encoding: chunked"].each do |extra|
      client = TCPSocket.new("127.0.0.1", @port)
      client.write("POST /api/run HTTP/1.1\r\nHost: 127.0.0.1:#{@port}\r\n#{extra}\r\n\r\n{}")
      assert_match(/HTTP\/1.1 400/, client.read)
      client.close
    end
    assert_equal "idle", JSON.parse(request.body)["status"]
  end

  def test_interrupted_state_does_not_reuse_a_saved_pid
    shutdown
    File.write(File.join(@state, "run.json"), JSON.generate({ status: "running", prompt: "old", result: "", exit_code: "", pid: Process.pid }))
    launch
    assert_equal "interrupted", JSON.parse(request.body)["status"]
    assert_equal "200", request("POST", "/api/run", { prompt: "new" }).code
    wait_for("succeeded")
  end
end

checks = SpinelWebPrototypeTest.instance_methods(false).grep(/^test_/).sort
checks.each do |check|
  test = SpinelWebPrototypeTest.new
  begin
    test.setup
    test.public_send(check)
  rescue StandardError
    directory = test.instance_variable_get(:@directory)
    log = directory && File.join(directory, "server.log")
    warn File.read(log) if log && File.file?(log)
    warn "Failed: #{check}"
    raise
  ensure
    test.teardown
  end
end
puts "spinel_web_prototype_test: ok (#{checks.length} checks)"
