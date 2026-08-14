# frozen_string_literal: true

require "json"

require_relative "agent_archive_store"
require_relative "agent_memory"
require_relative "delegation_store"

module HQ
  class DelegationCoordinator
    def initialize(delegation_store: DelegationStore.new, archive_store: AgentArchiveStore.new)
      @delegation_store = delegation_store
      @archive_store = archive_store
    end

    attr_reader :delegation_store

    def attach!(agents:, child:, parent_key:, parent_server_id: nil, now: Time.now)
      key = parent_key.to_s.strip
      raise DelegationStore::Error, "Missing parent agent key" if key.empty?

      parent = agents.find { |agent| agent.key == key }
      raise DelegationStore::Error, "Unknown parent agent: #{key}" unless parent

      parent.refresh_session_identity!

      relation, created = delegation_store.attach!(
        parent:,
        child:,
        parent_server_id:,
        now:
      )
      child.associate_parent!(relation.fetch("parent"))
      AgentMemory.new(parent).append_delegation_event!(
        "Started agent #{child.display_name}",
        event_id: "delegation-created:#{relation.fetch("id")}",
        created_at: now,
        metadata: {
          "relationship_id" => relation.fetch("id"),
          "event" => "agent_started",
          "agent_reference" => relation.fetch("child")
        }
      )
      [relation, created]
    end

    def process!(agents, now: Time.now)
      changed = false
      agents.each do |child|
        _report, created = delegation_store.record_report!(child:, now:)
        changed ||= created
      end

      pending = delegation_store.reports.select { |report| report["delivered_at"].to_s.empty? }
      pending.each do |report|
        changed = deliver_report!(report, agents, now:) || changed
      end

      resume_parents!(agents, now:) || changed
    end

    def relationships_for(agent_key, index: nil)
      index ||= relationship_index
      {
        "parent" => index.fetch(:parents)[agent_key.to_s],
        "children" => index.fetch(:children).fetch(agent_key.to_s, [])
      }
    end

    def relationship_index
      parents = {}
      children = Hash.new { |hash, key| hash[key] = [] }
      delegation_store.relationships.each do |relation|
        parents[relation.dig("child", "agent_key")] = relation
        children[relation.dig("parent", "agent_key")] << relation
      end
      { parents:, children: }
    end

    private

    def deliver_report!(report, agents, now:)
      parent_key = report.fetch("parent_agent_key")
      parent = agents.find { |agent| agent.key == parent_key }
      archived = nil
      unless parent
        archived = @archive_store.find(parent_key)
        parent = archived&.agent
      end
      unless parent
        delegation_store.update_report!(report.fetch("id"), resume_state: "parent_missing")
        return false
      end

      added = AgentMemory.new(parent).append_delegation_report!(
        report_message(report),
        report_id: "delegation-report:#{report.fetch("id")}",
        created_at: now,
        metadata: {
          "delegation_report" => report,
          "agent_reference" => report.fetch("child")
        }
      )
      @archive_store.save(archived) if archived && added
      state = archived ? "parent_archived" : "queued"
      delegation_store.update_report!(report.fetch("id"), delivered_at: now, resume_state: state)
      true
    end

    def resume_parents!(agents, now:)
      changed = false
      resumable_reports.group_by { |report| report.fetch("parent_agent_key") }.each do |parent_key, reports|
        parent = agents.find { |agent| agent.key == parent_key }
        unless parent
          reports.each { |report| delegation_store.update_report!(report.fetch("id"), resume_state: "parent_archived") }
          next
        end

        if parent.running?
          reports.each { |report| delegation_store.update_report!(report.fetch("id"), resume_state: "parent_running") }
          next
        end

        parent_workspace = canonical_workspace(parent.workspace)
        conflicts = agents.any? do |agent|
          agent.key != parent.key && canonical_workspace(agent.workspace) == parent_workspace && agent.running?
        end
        if conflicts
          reports.each { |report| delegation_store.update_report!(report.fetch("id"), resume_state: "workspace_busy") }
          next
        end

        parent.start!
        state = parent.running? ? "resumed" : "resume_failed"
        reports.each do |report|
          options = { resume_state: state, resumed_at: (now if state == "resumed") }
          delegation_store.update_report!(report.fetch("id"), **options)
        end
        changed = true
      end
      changed
    end

    def resumable_reports
      delegation_store.reports.select do |report|
        !report["delivered_at"].to_s.empty? &&
          %w[queued parent_running workspace_busy].include?(report["resume_state"])
      end
    end

    def report_message(report)
      payload = {
        "type" => "delegated_agent_report",
        "report_id" => report.fetch("id"),
        "agent" => report.fetch("child"),
        "run_id" => report["child_run_id"],
        "run_number" => report["child_run_number"],
        "native_session_id" => report["child_native_session_id"],
        "status" => report.fetch("status"),
        "summary" => report.fetch("summary"),
        "inquiry" => report["inquiry"],
        "attachments" => report["attachments"]
      }.compact
      "Delegated agent report:\n#{JSON.pretty_generate(payload)}"
    end

    def canonical_workspace(path)
      File.realpath(path.to_s)
    rescue StandardError
      File.expand_path(path.to_s)
    end
  end
end
