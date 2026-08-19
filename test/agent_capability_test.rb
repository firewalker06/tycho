# frozen_string_literal: true

require "tmpdir"

require_relative "../lib/hq/domain/agent_capability"

class AgentCapabilityTest
  def self.run!
    Dir.mktmpdir("tycho-agent-capability") do |dir|
      path = File.join(dir, "capability.json")
      issuer = HQ::AgentCapability.new(path:, ttl: 60)
      now = Time.at(1_800_000_000)
      token = issuer.issue(agent_key: "parent", run_id: "run-1", now:)
      actor = issuer.verify(token, now: now + 30)
      assert(actor.agent? && actor.agent_key == "parent" && actor.run_id == "run-1",
             "expected a verified capability to preserve run provenance")
      assert(File.stat(path).mode & 0o777 == 0o600, "expected the capability secret to be owner-readable only")

      assert_raises("tampered capability") { issuer.verify("#{token}x", now: now + 30) }
      assert_raises("expired capability") { issuer.verify(token, now: now + 61) }
      assert(HQ::AgentCapability.user_actor.user?, "expected a separate user actor")
    end
    puts "agent_capability_test: ok"
  end

  def self.assert(condition, message)
    raise message unless condition
  end

  def self.assert_raises(message)
    yield
    raise "expected #{message} rejection"
  rescue HQ::AgentCapability::Error
    true
  end
end

AgentCapabilityTest.run! if $PROGRAM_NAME == __FILE__
