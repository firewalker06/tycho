# frozen_string_literal: true

require_relative "support/push_safety"
require "timeout"
require_relative "../lib/hq/remote_server"

module ProjectGitMetadataCacheTest
  module_function

  def assert(value, message)
    raise message unless value
  end

  FakeProject = Struct.new(:key, :path, :reader, :applied) do
    def refresh_metadata!
      reader.call
    end

    def apply_git_metadata(metadata)
      self.applied = metadata
    end
  end

  def take(queue)
    Timeout.timeout(5) { queue.pop }
  end

  def drain(cache)
    cache.instance_variable_get(:@mutex).synchronize { cache.instance_variable_get(:@workers).dup }.each do |worker|
      assert(worker.join(5), "metadata worker did not finish")
    end
  end

  def run!
    now = 0.0
    cache = HQ::ProjectGitMetadataCache.new(clock: -> { now })
    started = Queue.new
    release = Queue.new
    values = { branch: "main", commit_hash: "abcdef0", dirty_files: 0 }
    project = FakeProject.new("web", "/synthetic/web", -> { started << true; take(release) })
    begin
      cold = cache.request(project)
      assert(cold[:state] == "unknown" && cold[:refreshing], "cold demand must be unknown and asynchronous")
      take(started)
      20.times { cache.request(FakeProject.new("web", "/synthetic/web", -> { raise "duplicate read" })) }
      assert(started.empty?, "concurrent demand must coalesce")
      release << values
      drain(cache)
      assert(cache.request(project)[:state] == "fresh", "completed work must become fresh")
      assert(cache.request(project)[:metadata] == values, "shared cache must retain all values")
      assert(cache.instance_variable_get(:@workers).empty?, "fresh requests must not start Git")
    ensure
      release << values
      cache.close
    end

    # A new attempt can fail wholly or partly. Keep good fields, but never certify
    # the combined old/new snapshot as a current clean result.
    cache = HQ::ProjectGitMetadataCache.new(clock: -> { now })
    cache.refresh(FakeProject.new("web", project.path, -> { values }))
    now = HQ::ProjectGitMetadataCache::FRESHNESS_WINDOW + 1
    gate = Queue.new
    stale_project = FakeProject.new("web", project.path, -> { started << true; take(gate) })
    begin
      stale = cache.request(stale_project)
      assert(stale[:state] == "stale" && stale[:metadata][:dirty_files] == 0, "stale clean data must be marked stale")
      take(started)
      gate << { dirty_files: 2 }
      drain(cache)
      failed = cache.request(project)
      assert(failed[:state] == "failed", "partial failures must be unavailable")
      assert(!failed[:refreshing], "failed attempts must wait for the retry window")
      assert(failed[:metadata] == values.merge(dirty_files: 2), "partial failures must preserve good fields")
      cache.refresh(FakeProject.new("web", project.path, -> { raise "synthetic failure" }))
      assert(cache.request(project)[:metadata] == failed[:metadata], "exceptions must preserve previous metadata")
      cache.refresh(FakeProject.new("web", project.path, -> { values.merge(branch: nil) }))
      assert(cache.request(project)[:state] == "fresh" && cache.request(project)[:metadata][:branch].nil?, "detached HEAD is valid")
      cache.refresh(FakeProject.new("web", project.path, -> { values.merge(commit_hash: nil) }))
      assert(cache.request(project)[:state] == "fresh", "unborn branches can have a valid nil revision")
    ensure
      gate << {}
      cache.close
    end

    now = 0.0
    cache = HQ::ProjectGitMetadataCache.new(clock: -> { now })
    gates = Array.new(2) { Queue.new }
    begin
      2.times do |index|
        cache.request(FakeProject.new("busy-#{index}", "/#{index}", -> { started << index; take(gates[index]); values }))
        assert(take(started) == index, "both global workers must run")
      end
      46.times do |index|
        cache.request(FakeProject.new("queued-#{index}", "/queued/#{index}", -> { started << :unexpected; values }))
      end
      assert(cache.instance_variable_get(:@workers).length == 2, "many projects must use only two workers")
      assert(started.empty?, "queued work must not start extra workers")
      now = HQ::ProjectGitMetadataCache::FRESHNESS_WINDOW + 1
      # Drain without closing so expired queued demand must be discarded by workers.
      gates.each { |queue| queue << true }
      drain(cache)
      assert(started.empty?, "inactive queued demand must expire without Git")
      assert(cache.instance_variable_get(:@workers).empty?, "workers must leave after demand drains")
      retry_project = FakeProject.new("queued-0", "/queued/0", -> { started << :retry; values })
      assert(cache.request(retry_project)[:refreshing], "expired demand must be eligible on the next detail read")
      assert(take(started) == :retry, "new active demand must run")
    ensure
      gates.each { |queue| queue << true }
      cache.close
    end
    puts "project_git_metadata_cache_test: ok"
  end
end

ProjectGitMetadataCacheTest.run!
