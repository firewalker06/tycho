# frozen_string_literal: true

require "bubbles"

module HQ
  module UI
    module TextAreaWrapping
      module_function

      def wrapped_view_lines(input)
        rendered_wrapped_lines(input).first
      end

      def visible_wrapped_lines(input, height)
        lines, cursor_line = rendered_wrapped_lines(input)
        height = [height, 1].max

        return lines if lines.length <= height

        offset = if input.focused?
                   [cursor_line - height + 1, 0].max
                 else
                   lines.length - height
                 end

        lines.slice(offset, height) || []
      end

      def wrapped_line_count(input)
        wrap_text_lines(input.value.to_s, wrap_width(input)).length
      end

      def rendered_wrapped_lines(input)
        rendered = []
        cursor_visual_row = 0

        input.value.to_s.split("\n", -1).each_with_index do |line, row_index|
          segments, cursor_segment, cursor_column = wrapped_segments(input, line, row_index)

          segments.each_with_index do |segment, segment_index|
            if input.focused? && row_index == input.row && segment_index == cursor_segment
              rendered << render_cursor_segment(input, segment, cursor_column)
              cursor_visual_row = rendered.length - 1
            else
              rendered << segment
            end
          end
        end

        rendered = [""] if rendered.empty?
        [rendered, cursor_visual_row]
      end

      def wrapped_segments(input, line, row_index)
        text = line.to_s
        width = wrap_width(input)
        ranges = wrapped_ranges(text, width)
        segments = ranges.map { |start_index, end_index| text[start_index...end_index] }
        segments = [""] if segments.empty?

        return [segments, nil, nil] unless row_index == input.row

        if text.empty?
          [segments, 0, 0]
        elsif input.focused? && input.col == text.length && segments.last.length == width
          [segments + [""], segments.length, 0]
        else
          segment_index, column = cursor_position_for(ranges, input.col)
          [segments, segment_index, column]
        end
      end

      def wrap_text_lines(text, width)
        lines = text.split("\n", -1).flat_map do |line|
          ranges = wrapped_ranges(line, width)
          ranges.map { |start_index, end_index| line[start_index...end_index] }
        end
        lines.empty? ? [""] : lines
      end

      def wrapped_ranges(text, width)
        line = text.to_s
        return [[0, 0]] if line.empty?

        ranges = []
        start_index = 0

        while start_index < line.length
          remaining = line.length - start_index
          if remaining <= width
            ranges << [start_index, line.length]
            break
          end

          candidate_end = start_index + width
          break_at = line.rindex(/\s/, candidate_end - 1)
          break_at = nil if break_at && break_at < start_index

          if break_at
            end_index = break_at + 1
            end_index += 1 while end_index < line.length && line[end_index].match?(/\s/)
          else
            end_index = candidate_end
          end

          ranges << [start_index, end_index]
          start_index = end_index
        end

        ranges
      end

      def cursor_position_for(ranges, column)
        ranges.each_with_index do |(start_index, end_index), index|
          return [index, column - start_index] if column >= start_index && column < end_index
        end

        last_index = [ranges.length - 1, 0].max
        last_start, last_end = ranges[last_index]
        [last_index, [column - last_start, last_end - last_start].min]
      end

      def wrap_width(input)
        [input.width, 1].max
      end

      def render_cursor_segment(input, segment, cursor_column)
        before = segment[0...cursor_column] || ""
        char = segment[cursor_column] || " "
        after = segment[(cursor_column + 1)..] || ""

        input.cursor.char = char
        "#{before}#{input.cursor.view}#{after}"
      end
    end
  end
end
