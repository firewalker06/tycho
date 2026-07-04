# frozen_string_literal: true

module HQ
  module UI
    module Rendering
      module TextHelpers
        private

        def icon_label(kind, value, label: nil)
          icon = icon_for(kind, value)
          label ||= value.respond_to?(:name) ? value.name.to_s : value.to_s
          icon ? "#{icon} #{label}" : label
        end

        def icon_for(kind, value)
          Styles::ICONS[kind]
        end

        def wrap_text(text, width)
          text.to_s.split("\n").map do |line|
            wrap_line(line, width)
          end.join("\n")
        end

        def wrap_line(line, width)
          stripped = line.to_s.rstrip
          return "" if stripped.empty?

          words = stripped.split(/\s+/)
          lines = [words.shift]
          words.each do |word|
            if "#{lines.last} #{word}".length <= width
              lines[-1] = "#{lines.last} #{word}"
            else
              lines << word
            end
          end
          lines.join("\n")
        end

        def truncate(text, width)
          text = text.to_s
          return text if text.length <= width

          "#{text[0, width - 1]}…"
        end

        def fit_cell(text, width)
          truncate(text.to_s, width).ljust(width)
        end

        def pad_visible(text, width)
          visible = visible_width(text)
          return text if visible >= width

          "#{text}#{" " * (width - visible)}"
        end

        def pad_row(line)
          row_width = table_content_width + 3
          visible = visible_width(line)
          return line if visible >= row_width

          "#{line}#{" " * (row_width - visible)}"
        end

        # Character ranges that render as 2 columns in a monospace terminal.
        # Deliberately excludes the Private Use Area — Nerd Font / Codicon
        # glyphs are rendered at single width in many monospace setups (and
        # Lipgloss counts them as 1 column), so treating them as wide here
        # causes compounding padding errors.
        DOUBLE_WIDTH_RANGES = [
          0x1100..0x115F,    # Hangul Jamo
          0x2E80..0x303E,    # CJK Radicals, Kangxi
          0x3041..0x33FF,    # Hiragana, Katakana, CJK Symbols
          0x3400..0x4DBF,    # CJK Ext A
          0x4E00..0x9FFF,    # CJK Unified
          0xA000..0xA4CF,    # Yi
          0xAC00..0xD7A3,    # Hangul Syllables
          0xF900..0xFAFF,    # CJK Compat
          0xFE30..0xFE4F,    # CJK Compat Forms
          0xFF00..0xFF60,    # Fullwidth Forms
          0xFFE0..0xFFE6,    # Fullwidth Signs
          0x1F300..0x1F64F,  # Misc Symbols & Pictographs, Emoticons
          0x1F680..0x1F6FF,  # Transport & Map
          0x1F900..0x1F9FF   # Supplemental Symbols & Pictographs
        ].freeze

        OSC8_PATTERN = /\e\]8;[^\e]*\e\\/.freeze

        def visible_width(text)
          stripped = Bubbles::ANSI.strip(text.to_s).gsub(OSC8_PATTERN, "")
          width = 0
          stripped.each_char do |char|
            cp = char.ord
            width += double_width_codepoint?(cp) ? 2 : 1
          end
          width
        end

        def double_width_codepoint?(cp)
          DOUBLE_WIDTH_RANGES.any? { |range| range.cover?(cp) }
        end

        # Count of characters in `text` that render as 2 columns in the
        # terminal but are counted as 1 by Lipgloss's internal width logic.
        # Use this to compensate when a row is wrapped in a Lipgloss style
        # with `.width(n)` — we need to under-pad by this delta so Lipgloss
        # stops padding at the visually-correct column.
        def wide_char_excess(text)
          stripped = Bubbles::ANSI.strip(text.to_s)
          count = 0
          stripped.each_char { |c| count += 1 if double_width_codepoint?(c.ord) }
          count
        end

        # Wrap `label` in an OSC 8 hyperlink escape sequence so terminals
        # that support it (iTerm2, WezTerm, Kitty, Ghostty, …) render it as
        # clickable. Terminals that don't support it render `label` plainly.
        def osc8_link(url, label)
          return label.to_s if url.to_s.empty?

          "\e]8;;#{url}\e\\#{label}\e]8;;\e\\"
        end

        # Render a chip: icon + space + label, optionally wrapped in an OSC 8
        # hyperlink. The returned string reports `visible_width` as just the
        # plain content — hyperlink escapes are ignored by Bubbles::ANSI.strip.
        def chip(icon, label, url: nil)
          text = "#{icon} #{label}".rstrip
          url ? osc8_link(url, text) : text
        end

        # Pad `text` so that Lipgloss (which under-counts wide chars) sees it
        # as `target` wide. When the containing Lipgloss style later pads to a
        # fixed width, the final visible column count will match `target`.
        def pad_for_lipgloss(text, target)
          lipgloss_width = visible_width(text) - wide_char_excess(text)
          return text if lipgloss_width >= target

          "#{text}#{" " * (target - lipgloss_width)}"
        end

        def time_ago(time)
          seconds = (Time.now - time).to_i
          return "#{seconds}s" if seconds < 60
          return "#{seconds / 60}m" if seconds < 3600
          return "#{seconds / 3600}h" if seconds < 86_400

          "#{seconds / 86_400}d"
        end

        def format_time(time)
          return "n/a" unless time

          time.strftime("%Y-%m-%d %H:%M:%S")
        end

        def compact_workspace_path(path)
          text = path.to_s.strip
          return text if text.empty?

          absolute = text.start_with?("/")
          segments = text.split("/").reject(&:empty?)
          return text if segments.length <= 2

          "#{absolute ? "/" : ""}#{segments.first}/.../#{segments.last}/"
        end

        def obfuscate_ip(ip)
          parts = ip.to_s.split(".")
          return ip unless parts.length == 4

          masked = parts[0..-2].map { |part| "*" * part.length }
          (masked + [parts.last]).join(".")
        end

        def fade_token_usage(text)
          text.to_s.gsub(/tokens used [0-9.]+/i) { |match| dim_style.render(match) }
        end

        def line_count(text)
          text.to_s.split("\n", -1).length
        end

        def trim_block_lines(text, max_lines)
          lines = text.to_s.split("\n", -1)
          return text if lines.length <= max_lines

          lines.first(max_lines).join("\n")
        end

        def pad_block_lines(text, target_lines)
          lines = text.to_s.split("\n", -1)
          return text if lines.length >= target_lines

          (lines + Array.new(target_lines - lines.length, "")).join("\n")
        end

        def join_left_right(left, right)
          width = [@window_width - (horizontal_margin * 2), 20].max
          left_width = visible_width(left)
          right_width = visible_width(right)
          gap = [width - left_width - right_width, 1].max
          "#{horizontal_margin_prefix}#{left}#{" " * gap}#{right}"
        end

        def wrap_rendered_segments(segments, prefix:, width:)
          return [prefix] if segments.empty?

          lines = []
          current = prefix.dup
          current_width = visible_width(current)

          segments.each do |segment|
            separator = current == prefix ? "" : " "
            segment_width = visible_width(segment) + separator.length

            if current_width + segment_width <= width
              current << separator << segment
              current_width += segment_width
            else
              lines << current.rstrip
              current = "#{prefix}#{segment}"
              current_width = visible_width(current)
            end
          end

          lines << current.rstrip
          lines
        end
      end
    end
  end
end
