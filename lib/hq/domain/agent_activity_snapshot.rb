# frozen_string_literal: true

require "thread"
require "time"

module HQ
  class AgentActivitySnapshot
    SCHEMA_VERSION = 1

    def initialize
      @mutex = Mutex.new
      @revision = 0
      @generated_at = nil
      @ready = false
      @agents = {}
    end

    def replace!(agents)
      replacement = Array(agents).to_h { |agent| [agent.key, activity_payload(agent)] }
      @mutex.synchronize do
        return false if @ready && @agents == replacement

        @agents = replacement
        changed!
      end
      true
    end

    def upsert!(agent)
      payload = activity_payload(agent)
      @mutex.synchronize do
        return false if @ready && @agents[agent.key] == payload

        @agents[agent.key] = payload
        changed!
      end
      true
    end

    def remove!(key)
      @mutex.synchronize do
        removed = @agents.delete(key.to_s)
        return false unless removed

        changed!
      end
      true
    end

    def snapshot
      @mutex.synchronize do
        agents = activity_agents_with_topology
        {
          schema_version: SCHEMA_VERSION,
          revision: @revision,
          generated_at: @generated_at,
          ready: @ready,
          unread_count: agents.count { |agent| agent[:unread] },
          agents: agents
        }
      end
    end

    private

    def changed!
      @revision += 1
      @generated_at = Time.now.utc.iso8601
      @ready = true
    end

    def activity_payload(agent)
      status = agent.status
      {
        key: agent.key,
        name: agent.display_name,
        project_key: agent.project_key,
        template_key: agent.template_key,
        scheduled: agent.scheduled?,
        schedule_key: agent.schedule_key,
        agent: agent.agent,
        model: agent.model,
        reasoning_effort: agent.reasoning_effort,
        status: status,
        running: status == "running",
        unread: agent.unread?,
        awaiting_input: status == "awaiting-input",
        blocked: status == "blocked",
        run_count: agent.run_count,
        created_at: agent.created_at&.iso8601,
        started_at: agent.started_at&.iso8601,
        finished_at: agent.finished_at&.iso8601,
        updated_at: agent.last_activity_at&.iso8601,
        last_exit_code: agent.last_exit_code,
        last_result: agent.last_result_label,
        summary: agent.last_summary,
        archived: agent.archived?,
        archived_at: agent.archived_at&.iso8601,
        delegation: {
          parent: activity_parent_reference(agent.delegation_parent),
          children: []
        }
      }
    end

    def activity_agents_with_topology
      agents = @agents.values.sort_by { |agent| agent.fetch(:key) }.map do |agent|
        copy = agent.dup
        delegation = agent.fetch(:delegation)
        copy[:delegation] = {
          parent: delegation[:parent]&.dup,
          children: []
        }
        copy
      end
      by_key = agents.to_h { |agent| [agent.fetch(:key), agent] }

      agents.each do |child|
        parent = child.dig(:delegation, :parent)
        next unless parent

        parent_key = parent.fetch(:agent_key)
        parent[:state] = by_key.key?(parent_key) ? "active" : "missing"
        owner = by_key[parent_key]
        owner[:delegation][:children] << activity_child_reference(child, parent) if owner
      end
      agents
    end

    def activity_parent_reference(reference)
      return nil unless reference.is_a?(Hash)

      %w[server_id server_name agent_key name project_key].each_with_object({}) do |key, result|
        value = reference[key]
        result[key.to_sym] = value unless value.nil? || value.to_s.empty?
      end
    end

    def activity_child_reference(child, parent)
      {
        server_id: parent[:server_id],
        agent_key: child.fetch(:key),
        name: child[:name],
        project_key: child[:project_key],
        state: "active"
      }.compact
    end
  end
end
