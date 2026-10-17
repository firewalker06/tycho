# frozen_string_literal: true

require "socket"
require "json"
require "securerandom"

# A deliberately small, single-writer experiment. Do not load HQ or its gems.
class PrototypeRun
  def initialize(root, workspace, executable, model, fixture)
    @root = root
    @workspace = workspace
    @executable = executable
    @model = model
    @fixture = fixture
    @pid = 0
    @waiter = Thread.new { "" }
    @deadline = 0.0
    @stop_at = 0.0
    @kill_sent = false
    @record = { "status" => "idle", "prompt" => "", "result" => "", "exit_code" => "" }
    if File.exist?(state_path)
      data = JSON.parse(File.read(state_path))
      @record["status"] = data.fetch("status").to_s
      @record["prompt"] = data.fetch("prompt").to_s
      @record["result"] = data.fetch("result").to_s
      @record["exit_code"] = data.fetch("exit_code").to_s
      if ["running", "stopping"].include?(@record["status"])
        @record["status"] = "interrupted"
        save
      end
    end
  end

  def state_path
    File.join(@root, "run.json")
  end

  def log_path
    File.join(@root, "events.jsonl")
  end

  def result_path
    File.join(@root, "result.txt")
  end

  def save
    temporary = state_path + ".tmp"
    File.open(temporary, "w", 0o600) do |file|
      file.write(JSON.generate(@record))
      file.flush
      file.fsync
    end
    File.rename(temporary, state_path)
  end

  def active?
    @pid > 0
  end

  def start(prompt)
    raise "A run is already active" if active?
    raise "Prompt must contain 1 to 4000 bytes" if prompt.strip.empty? || prompt.bytesize > 4000

    File.write(log_path, "")
    File.write(result_path, "")
    @record = { "status" => "running", "prompt" => prompt, "result" => "", "exit_code" => "" }
    save
    # Never pass server tokens or Ruby loader state to a harness.
    environment = { "RUBYOPT" => nil, "RUBYLIB" => nil, "BUNDLE_GEMFILE" => nil,
                    "BUNDLE_BIN_PATH" => nil, "GEM_HOME" => nil, "GEM_PATH" => nil,
                    "TYCHO_GITHUB_TOKEN" => nil, "TYCHO_REMOTE_TOKEN" => nil }
    ENV.keys.each do |key|
      environment[key] = nil if key.start_with?("TYCHO_PROTO_", "BUNDLE_", "BUNDLER_")
    end
    command = if @fixture
                [@executable, prompt, result_path]
              else
                [@executable, "exec", "--ignore-user-config", "--ephemeral",
                 "--skip-git-repo-check", "--sandbox", "read-only",
                 "-c", "approval_policy=\"never\"", "--model", @model] + PrototypePlatform.codex_options + [
                 "--json", "--color", "never", "--output-last-message", result_path,
                 "--", prompt]
              end
    @pid = PrototypePlatform.spawn(environment, command, @workspace, log_path)
    child_pid = @pid
    @waiter = Thread.new do
      waited = Process.waitpid2(child_pid)
      waited[1].exitstatus.to_s
    end
    @deadline = Time.now.to_f + 180.0
    @stop_at = 0.0
    @kill_sent = false
  rescue StandardError
    @record["status"] = "failed"
    save unless active?
    raise
  end

  def signal_group(signal)
    PrototypePlatform.signal(@pid, signal) if active?
  rescue Errno::ESRCH
    nil
  rescue Errno::EPERM
    # Darwin can report EPERM for a group with no live members after exit.
    raise if @waiter.alive?
  end

  def stop
    return unless active?
    return if @record["status"] == "stopping"

    @record["status"] = "stopping"
    @stop_at = Time.now.to_f + 1.0
    signal_group("TERM")
    save
  end

  def poll
    return unless active?

    stop if Time.now.to_f >= @deadline || File.size(log_path) > 1_048_576
    if @stop_at > 0.0
      return if Time.now.to_f < @stop_at

      unless @kill_sent
        signal_group("KILL")
        @kill_sent = true
      end
    end
    return if @waiter.alive?

    exit_code = @waiter.value.to_s
    @pid = 0
    @record["status"] = if @record["status"] == "stopping"
                          "stopped"
                        elsif exit_code == "0"
                          "succeeded"
                        else
                          "failed"
                        end
    @record["exit_code"] = exit_code
    @record["result"] = File.read(result_path, 65_536).to_s
    save
  end

  def snapshot
    poll
    # These files are private. The API exposes only bounded text after authentication.
    output = File.exist?(log_path) ? File.read(log_path, 65_536).to_s : ""
    JSON.generate({ "status" => @record["status"], "prompt" => @record["prompt"],
                    "result" => @record["result"], "exit_code" => @record["exit_code"],
                    "output" => output, "harness" => @fixture ? "fixture" : "codex" })
  end

  def shutdown
    return unless active?

    stop
    sleep 1.0
    signal_group("KILL") unless @kill_sent
    @waiter.join
    @pid = 0
    @record["status"] = "interrupted"
    save
  rescue Errno::ECHILD
    @pid = 0
  end
end

# Strict HTTP/1.1 subset, for this loopback-only prototype behind Tailscale Serve.
# No keep-alive, chunked requests, uploads, generic file serving, or shell commands.
class PrototypeServer
  def initialize
    File.umask(0o077)
    root = ENV.fetch("TYCHO_PROTO_STATE")
    workspace = ENV.fetch("TYCHO_PROTO_WORKSPACE")
    raise "Use absolute state and workspace paths" unless File.absolute_path?(root) && File.absolute_path?(workspace)
    raise "Workspace must exist" unless File.directory?(workspace)
    PrototypePlatform.prepare(root)
    @lock = File.open(File.join(root, "lock"), "w", 0o600)
    raise "State is already in use" unless @lock.flock(File::LOCK_EX | File::LOCK_NB)
    token_path = File.join(root, "access-token")
    File.write(token_path, SecureRandom.hex(32)) unless File.exist?(token_path)
    @token = File.read(token_path).strip
    raise "Invalid access token" unless @token.match?(/\A[0-9a-f]{64}\z/)
    @port = Integer(ENV.fetch("TYCHO_PROTO_PORT", "7483"))
    raise "Invalid port" unless @port >= 1024 && @port <= 65535
    @local_origin = "http://127.0.0.1:#{@port}"
    @remote_origin = ENV.fetch("TYCHO_PROTO_ORIGIN", "")
    unless @remote_origin.empty? || @remote_origin.match?(/\Ahttps:\/\/[a-z0-9-]+\.[a-z0-9-]+\.ts\.net:[0-9]+\z/)
      raise "Remote origin must be the exact Tailscale HTTPS URL, with port"
    end
    @local_host = "127.0.0.1:#{@port}"
    @remote_host = @remote_origin.delete_prefix("https://")
    executable = ENV.fetch("TYCHO_PROTO_EXECUTABLE")
    raise "Harness must be an absolute executable path" unless File.absolute_path?(executable) && File.executable?(executable)
    @run = PrototypeRun.new(root, workspace, executable,
                            ENV.fetch("TYCHO_PROTO_MODEL", "gpt-6.1-sol"),
                            ENV.fetch("TYCHO_PROTO_FIXTURE", "0") == "1")
    @running = true
    puts "Prototype: #{@local_origin}"
    puts "Private access token file: #{token_path}"
  end

  def authorized?(header)
    expected = "Bearer #{@token}"
    return false unless header.bytesize == expected.bytesize

    different = 0
    index = 0
    while index < expected.bytesize
      different |= header.getbyte(index) ^ expected.getbyte(index)
      index += 1
    end
    different == 0
  end

  def read_piece(client, deadline)
    remaining = deadline - Time.now.to_f
    raise "Request timeout" if remaining <= 0 || IO.select([client], nil, nil, remaining).nil?

    client.readpartial(1024)
  end

  def handle(client)
    deadline = Time.now.to_f + 3.0
    input = +""
    until input.include?("\r\n\r\n")
      input << read_piece(client, deadline)
      raise "Headers too large" if input.bytesize > 16_384
    end
    parts = input.split("\r\n\r\n", 2)
    lines = parts[0].split("\r\n")
    first = lines.shift.to_s.split(" ")
    raise "Invalid request line" unless first.length == 3 && first[2] == "HTTP/1.1"
    method = first[0]
    path = first[1]
    headers = { "host" => "", "authorization" => "", "origin" => "" }
    seen = []
    lines.each do |line|
      pair = line.split(":", 2)
      raise "Invalid header" unless pair.length == 2 && pair[0].match?(/\A[A-Za-z0-9-]+\z/)
      name = pair[0].downcase
      raise "Duplicate header" if seen.include?(name)
      seen << name
      headers[name] = pair[1].strip
    end
    raise "Unsupported transfer encoding" if headers.key?("transfer-encoding")
    raise "Invalid host" unless headers["host"] == @local_host || (!@remote_host.empty? && headers["host"] == @remote_host)
    length = headers.fetch("content-length", "0")
    raise "Invalid length" unless length.match?(/\A[0-9]{1,5}\z/) && length.to_i <= 8192
    body = parts[1].to_s
    while body.bytesize < length.to_i
      body << read_piece(client, deadline)
    end
    raise "Unexpected request bytes" unless body.bytesize == length.to_i
    if method == "GET" && path == "/"
      respond(client, 200, "text/html; charset=utf-8", PrototypeAssets::HTML)
    elsif method == "GET" && path == "/app.js"
      respond(client, 200, "text/javascript; charset=utf-8", PrototypeAssets::JS)
    elsif method == "GET" && path == "/app.css"
      respond(client, 200, "text/css; charset=utf-8", PrototypeAssets::CSS)
    elsif !authorized?(headers["authorization"])
      respond(client, 401, "application/json", JSON.generate({ "error" => "Access token required" }))
    elsif method == "GET" && path == "/api/run"
      respond(client, 200, "application/json", @run.snapshot)
    elsif method == "POST" && ["/api/run", "/api/stop"].include?(path)
      origin = headers["origin"]
      unless origin == @local_origin || (!@remote_origin.empty? && origin == @remote_origin)
        respond(client, 403, "application/json", JSON.generate({ "error" => "Origin rejected" }))
        return
      end
      unless headers.fetch("content-type", "") == "application/json"
        respond(client, 415, "application/json", JSON.generate({ "error" => "JSON required" }))
        return
      end
      if path == "/api/run"
        if @run.active?
          respond(client, 409, "application/json", JSON.generate({ "error" => "A run is already active" }))
          return
        end
        data = JSON.parse(body)
        prompt = data.fetch("prompt")
        raise "Prompt must be text" unless prompt.is_a?(String)
        @run.start(prompt)
      else
        @run.stop
      end
      respond(client, 200, "application/json", @run.snapshot)
    else
      respond(client, 404, "application/json", JSON.generate({ "error" => "Route not found" }))
    end
  rescue StandardError
    respond(client, 400, "application/json", JSON.generate({ "error" => "Request rejected" }))
  ensure
    client.close
  end

  def respond(client, code, type, body)
    headers = "HTTP/1.1 #{code} Response\r\nContent-Type: #{type}\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'\r\n\r\n"
    client.write(headers + body)
  rescue IOError, SystemCallError
    nil
  end

  def serve
    server = TCPServer.new("127.0.0.1", @port)
    Signal.trap("TERM") { @running = false }
    Signal.trap("INT") { @running = false }
    while @running
      @run.poll
      handle(server.accept) unless IO.select([server], nil, nil, 0.2).nil?
    end
    server.close
  ensure
    @run.shutdown
    @lock.close
  end
end

PrototypeServer.new.serve
