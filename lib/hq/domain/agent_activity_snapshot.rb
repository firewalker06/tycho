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
        agents = @agents.values.sort_by { |agent| agent.fetch(:key) }.map(&:dup)
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
        archived_at: agent.archived_at&.iso8601
      }
    end
  end
end
