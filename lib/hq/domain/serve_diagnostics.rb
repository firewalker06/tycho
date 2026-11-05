# frozen_string_literal: true

module HQ
  # A bounded process-local sample window. No request values enter this store.
  class ServeDiagnostics
    SAMPLE_LIMIT = 1024
    METRICS = %w[admission store_lock_wait store_lock_hold route write].freeze
    RESOURCES = %w[
      agents activity servers projects schedules settings setup summary diagnostics
      resources metrics skills quick-agent search memory-handoffs update server
    ].freeze
    ACTIONS = %w[
      archived archive conversation reading attachments download preview summary
      chat inquiry run stop clone messages queue process remove resources refresh
      activity credentials update proxy diff diffs pull-requests logs memory
      daemon start restart reload archive-sessions install welcome harnesses
      auth-check catalog hidden quick-agent session-loops defaults prompt-templates
      response-style options backfill serve
    ].freeze

    def initialize
      @mutex = Mutex.new
      @accepted = 0
      @samples = []
    end

    def accept
      @mutex.synchronize { @accepted += 1 }
    end

    def record(request, timing)
      resource = request&.path.to_s.split("/")[1]
      label = if resource == "ui" || resource == "assets"
                "ui"
              elsif RESOURCES.include?(resource)
                request.path.split("/").reject(&:empty?).first(8).map.with_index do |part, index|
                  index.zero? || ACTIONS.include?(part) ? part : ":id"
                end.join("/")
              else
                "other"
              end
      method = %w[GET POST PUT PATCH DELETE OPTIONS HEAD].include?(request&.method) ? request.method : "OTHER"
      stages = timing.stages_ms
      sample = { route: "#{method} /#{label}", response_bytes: timing.response_bytes || 0 }
      METRICS.each { |name| sample["#{name}_ms".to_sym] = stages.fetch(name, 0.0).round(3) }
      @mutex.synchronize do
        @samples.shift if @samples.size >= SAMPLE_LIMIT
        @samples << sample
      end
    end

    def snapshot
      @mutex.synchronize do
        { accepted_sockets: @accepted, sample_limit: SAMPLE_LIMIT, samples: @samples.map(&:dup) }
      end
    end
  end
end
