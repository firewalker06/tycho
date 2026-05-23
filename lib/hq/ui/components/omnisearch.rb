# frozen_string_literal: true

module HQ
  module UI
    class Omnisearch
      TYPE_PRIORITY = { agent: 0, project: 1 }.freeze

      Item = Struct.new(
        :type,
        :label,
        :detail,
        :search_text,
        :target_key,
        :source_index,
        :unread,
        keyword_init: true
      )

      attr_reader :query, :results, :selected_index

      def initialize
        @query = ""
        @index = []
        @results = []
        @selected_index = 0
      end

      def build_index!(agents:, projects:, reset_selection: true)
        project_names = projects.to_h { |project| [project.key, project.name.to_s] }
        project_items = projects.each_with_index.map do |project, index|
          build_item(:project, project.name, project.key, index)
        end
        agent_items = agents.each_with_index.map do |agent, index|
          project_name = project_names[agent.project_key] || "Unlinked"
          build_item(:agent, agent.name, agent.key, index, detail: project_name, unread: agent.unread?)
        end
        @index = agent_items + project_items
        refresh_results!(reset_selection:)
      end

      def update_key(key)
        case key
        when "backspace", "ctrl+h"
          @query = @query[0...-1].to_s
          refresh_results!(reset_selection: true)
        when "ctrl+u"
          @query = ""
          refresh_results!(reset_selection: true)
        when "space"
          @query += " "
          refresh_results!(reset_selection: true)
        when "up"
          move_selection(-1)
        when "down"
          move_selection(1)
        else
          append_key(key)
        end
      end

      def selected_item
        @results[@selected_index]
      end

      def empty_query?
        @query.empty?
      end

      private

      def build_item(type, label, target_key, source_index, detail: nil, unread: false)
        search_value = detail.to_s.empty? ? label.to_s : "#{label} #{detail}"
        Item.new(
          type:,
          label: label.to_s,
          detail: detail.to_s,
          search_text: normalize(search_value),
          target_key: target_key.to_s,
          source_index:,
          unread:
        )
      end

      def append_key(key)
        return unless printable_text_key?(key)

        @query += key
        refresh_results!(reset_selection: true)
      end

      def move_selection(delta)
        return if @results.empty?

        @selected_index = (@selected_index + delta) % @results.length
      end

      def refresh_results!(reset_selection: false)
        prior_item = selected_item
        @results = if @query.empty?
                     unread_agent_results
                   else
                     matched_results
                   end
        return @selected_index = 0 if reset_selection

        @selected_index = restored_selection_index(prior_item)
      end

      def unread_agent_results
        @index.select { |item| item.type == :agent && item.unread }
              .sort_by { |item| [item.source_index] }
      end

      def matched_results
        @index.filter_map do |item|
          score = fuzzy_score(@query, item.search_text)
          [item, score] if score
        end.sort_by do |item, score|
          [-score, TYPE_PRIORITY.fetch(item.type, 99), item.source_index]
        end.map(&:first)
      end

      def restored_selection_index(prior_item)
        return 0 if @results.empty?

        index = @results.index do |item|
          prior_item && item.type == prior_item.type && item.target_key == prior_item.target_key
        end
        index || [@selected_index, @results.length - 1].min
      end

      def fuzzy_score(query, candidate)
        query = normalize(query)
        candidate = normalize(candidate)
        return nil if query.empty? || candidate.empty?

        positions = []
        cursor = 0
        query.each_char do |char|
          found = candidate.index(char, cursor)
          return nil unless found

          positions << found
          cursor = found + 1
        end

        gaps = positions.each_cons(2).sum { |left, right| right - left - 1 }
        score = 1_000
        score += 500 if candidate.start_with?(query)
        score += 300 if candidate.include?(query)
        score += 100 if gaps.zero?
        score -= gaps * 10
        score -= positions.first * 3
        score
      end

      def normalize(value)
        value.to_s.downcase.strip.gsub(/\s+/, " ")
      end

      def printable_text_key?(key)
        text = key.to_s
        return false if text.empty?
        return false if text.start_with?("ctrl+", "alt+", "shift+")
        return false if %w[left right tab delete home end pgup pgdown esc escape enter].include?(text)

        text.each_char.all? { |char| char.ord >= 32 }
      end
    end
  end
end
