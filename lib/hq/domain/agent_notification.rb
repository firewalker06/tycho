# frozen_string_literal: true

require "uri"

module HQ
  # One payload and record shape for automatic alerts and operator test cases.
  module AgentNotification
    TYPES = {
      "succeeded" => { event: "finished", title: "Done" },
      "partial" => { event: "finished", title: "Partial" },
      "failed" => { event: "finished", title: "Failed" },
      "stopped" => { event: "finished", title: "Stopped" },
      "blocked" => { event: "finished", title: "Blocked" },
      "awaiting-input" => { event: "input_required", title: "Input needed" }
    }.transform_values(&:freeze).freeze

    def self.build(agent, status:, unread_count:, id:)
      type = TYPES.fetch(status)
      count = [unread_count.to_i, 1].max
      summary = agent.last_summary.to_s.gsub(/\s+/, " ").strip
      summary = "#{summary[0, 117]}..." if summary.length > 120
      body = "#{agent.display_name}: #{summary}"
      body += " (#{count} unread agents)" if count > 1
      input = type.fetch(:event) == "input_required"
      payload = {
        title: type.fetch(:title), body: body, tag: "hq:agents", renotify: input,
        silent: !input, badge_count: count, url: "/#notification/#{URI.encode_www_form_component(id)}"
      }
      {
        id: id, event: type.fetch(:event), payload: payload,
        urgency: input ? "high" : "normal", ttl: input ? 3600 : 900,
        record: {
          kind: "agent", target_type: "agent", target_state: "active", agent_key: agent.key,
          agent_name: agent.display_name, project_key: agent.respond_to?(:project_key) ? agent.project_key : nil,
          event: type.fetch(:event),
          status: status, run_count: agent.run_count, title: payload[:title], body: body, url: payload[:url]
        }
      }
    end
  end
end
