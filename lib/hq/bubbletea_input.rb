# frozen_string_literal: true

require "bubbletea"

module HQ
  # BubbleteaInput patches the Bubbletea input boundary used by this app.
  #
  # Why this exists:
  # Bubbletea::Program#poll_event reads a raw terminal buffer from the native
  # extension and asks the Go parser to parse one event from that buffer. The
  # parser reports how many bytes it consumed, but the Ruby C bridge discards
  # the unconsumed bytes. That is harmless for one keypress per read, but paste
  # usually arrives as many bytes in one read. Without this queue, pasting:
  #
  #   lib/hq/ui/components/chat_composer.rb
  #
  # only delivers "l" to Bubbles::TextInput/Bubbles::TextArea and drops the
  # rest of the path.
  #
  # How it works:
  # - install! aliases Bubbletea::Program#poll_event once.
  # - The replacement reads raw bytes with read_raw_input.
  # - parse_raw expands that raw buffer into the same event hashes Bubbletea
  #   normally returns from poll_event.
  # - Extra parsed events are stored in @hq_pending_events and returned on
  #   later poll_event calls before reading from the terminal again.
  #
  # Use cases covered:
  # - Fast pasted plain text, such as file paths, URLs, prompts, and shell
  #   snippets, where many printable characters arrive in one terminal read.
  # - Bracketed paste blocks, where the terminal wraps pasted text in
  #   ESC [ 200 ~ and ESC [ 201 ~. These are emitted as one KEY_RUNES event
  #   with all pasted runes so Bubbles inserts the paste in one operation.
  # - Bracketed paste blocks split across reads. The partial pasted text is
  #   kept in @hq_paste_buffer until the closing marker arrives.
  # - Normal navigation/control keys such as arrows, tab, enter, ctrl+s, and
  #   backspace. These are translated back to Bubbletea key names so the rest
  #   of HQ's update code can stay unchanged.
  #
  # This is intentionally local to HQ. If upstream Bubbletea starts preserving
  # unconsumed bytes or emits paste messages directly, this shim can be removed
  # after the paste regression tests keep passing without it.
  module BubbleteaInput
    BRACKETED_PASTE_START = "\e[200~"
    BRACKETED_PASTE_END = "\e[201~"

    ESCAPE_SEQUENCES = {
      "\e[A" => [Bubbletea::KeyMessage::KEY_UP, "up"],
      "\e[B" => [Bubbletea::KeyMessage::KEY_DOWN, "down"],
      "\e[C" => [Bubbletea::KeyMessage::KEY_RIGHT, "right"],
      "\e[D" => [Bubbletea::KeyMessage::KEY_LEFT, "left"],
      "\e[H" => [Bubbletea::KeyMessage::KEY_HOME, "home"],
      "\e[F" => [Bubbletea::KeyMessage::KEY_END, "end"],
      "\e[1~" => [Bubbletea::KeyMessage::KEY_HOME, "home"],
      "\e[4~" => [Bubbletea::KeyMessage::KEY_END, "end"],
      "\e[5~" => [Bubbletea::KeyMessage::KEY_PGUP, "pgup"],
      "\e[6~" => [Bubbletea::KeyMessage::KEY_PGDOWN, "pgdown"],
      "\e[2~" => [Bubbletea::KeyMessage::KEY_INSERT, "insert"],
      "\e[3~" => [Bubbletea::KeyMessage::KEY_DELETE, "delete"],
      "\eOP" => [Bubbletea::KeyMessage::KEY_F1, "f1"],
      "\eOQ" => [Bubbletea::KeyMessage::KEY_F2, "f2"],
      "\eOR" => [Bubbletea::KeyMessage::KEY_F3, "f3"],
      "\eOS" => [Bubbletea::KeyMessage::KEY_F4, "f4"],
      "\e[15~" => [Bubbletea::KeyMessage::KEY_F5, "f5"],
      "\e[17~" => [Bubbletea::KeyMessage::KEY_F6, "f6"],
      "\e[18~" => [Bubbletea::KeyMessage::KEY_F7, "f7"],
      "\e[19~" => [Bubbletea::KeyMessage::KEY_F8, "f8"],
      "\e[20~" => [Bubbletea::KeyMessage::KEY_F9, "f9"],
      "\e[21~" => [Bubbletea::KeyMessage::KEY_F10, "f10"],
      "\e[23~" => [Bubbletea::KeyMessage::KEY_F11, "f11"],
      "\e[24~" => [Bubbletea::KeyMessage::KEY_F12, "f12"],
      "\e[Z" => [Bubbletea::KeyMessage::KEY_SHIFT_TAB, "shift+tab"]
    }.freeze

    CONTROL_NAMES = {
      0 => "ctrl+@",
      1 => "ctrl+a",
      2 => "ctrl+b",
      3 => "ctrl+c",
      4 => "ctrl+d",
      5 => "ctrl+e",
      6 => "ctrl+f",
      7 => "ctrl+g",
      8 => "ctrl+h",
      9 => "tab",
      10 => "ctrl+j",
      11 => "ctrl+k",
      12 => "ctrl+l",
      13 => "enter",
      14 => "ctrl+n",
      15 => "ctrl+o",
      16 => "ctrl+p",
      17 => "ctrl+q",
      18 => "ctrl+r",
      19 => "ctrl+s",
      20 => "ctrl+t",
      21 => "ctrl+u",
      22 => "ctrl+v",
      23 => "ctrl+w",
      24 => "ctrl+x",
      25 => "ctrl+y",
      26 => "ctrl+z",
      27 => "esc",
      127 => "backspace"
    }.freeze

    module_function

    def parse_raw(raw, paste_buffer: nil)
      state = { paste_buffer: paste_buffer }
      events = parse_chunk(raw.to_s.b, state)
      [events, state[:paste_buffer]]
    end

    def parse_chunk(raw, state)
      return [] if raw.empty?

      # A previous terminal read started a bracketed paste but did not include
      # the closing marker. Continue accumulating until the paste is complete.
      return continue_bracketed_paste(raw, state) if state[:paste_buffer]

      events = []
      offset = 0

      while offset < raw.bytesize
        if starts_with_at?(raw, BRACKETED_PASTE_START, offset)
          offset += BRACKETED_PASTE_START.bytesize
          offset = read_bracketed_paste(raw, offset, events, state)
          break if state[:paste_buffer]

          next
        end

        sequence = matching_escape_sequence(raw, offset)
        if sequence
          key_type, name = ESCAPE_SEQUENCES.fetch(sequence)
          events << key_event(key_type: key_type, name: name)
          offset += sequence.bytesize
          next
        end

        byte = raw.getbyte(offset)
        if byte == 27
          events << key_event(key_type: Bubbletea::KeyMessage::KEY_ESC, name: "esc")
          offset += 1
        elsif byte && (byte < 32 || byte == 127)
          events << key_event(key_type: byte, name: CONTROL_NAMES.fetch(byte, "ctrl+?"))
          offset += 1
        elsif byte == 32
          events << key_event(key_type: Bubbletea::KeyMessage::KEY_SPACE, runes: [32], name: "space")
          offset += 1
        else
          char, size = next_utf8_char(raw, offset)
          if char
            events << key_event(key_type: Bubbletea::KeyMessage::KEY_RUNES, runes: [char.ord], name: char)
            offset += size
          else
            offset += 1
          end
        end
      end

      events
    end

    def continue_bracketed_paste(raw, state)
      end_index = raw.index(BRACKETED_PASTE_END)
      unless end_index
        state[:paste_buffer] << raw.force_encoding(Encoding::UTF_8)
        return []
      end

      text = state[:paste_buffer] + raw.byteslice(0...end_index).to_s.force_encoding(Encoding::UTF_8)
      state[:paste_buffer] = nil
      remainder_offset = end_index + BRACKETED_PASTE_END.bytesize
      [key_event(key_type: Bubbletea::KeyMessage::KEY_RUNES, runes: text.codepoints, name: text)] +
        parse_chunk(raw.byteslice(remainder_offset..).to_s.b, state)
    end

    def read_bracketed_paste(raw, offset, events, state)
      end_index = raw.index(BRACKETED_PASTE_END, offset)
      unless end_index
        state[:paste_buffer] = raw.byteslice(offset..).to_s.force_encoding(Encoding::UTF_8)
        return raw.bytesize
      end

      text = raw.byteslice(offset...end_index).to_s.force_encoding(Encoding::UTF_8)
      events << key_event(key_type: Bubbletea::KeyMessage::KEY_RUNES, runes: text.codepoints, name: text)
      end_index + BRACKETED_PASTE_END.bytesize
    end

    def matching_escape_sequence(raw, offset)
      ESCAPE_SEQUENCES.keys.find { |sequence| starts_with_at?(raw, sequence, offset) }
    end

    def starts_with_at?(raw, sequence, offset)
      raw.byteslice(offset, sequence.bytesize) == sequence
    end

    def next_utf8_char(raw, offset)
      string = raw.byteslice(offset..).to_s.force_encoding(Encoding::UTF_8)
      char = string.each_char.first
      return [nil, 0] unless char&.valid_encoding?

      [char, char.bytesize]
    end

    def key_event(key_type:, name:, runes: nil)
      {
        "type" => "key",
        "key_type" => key_type,
        "runes" => runes,
        "alt" => false,
        "name" => name
      }
    end

    def install!
      return if Bubbletea::Program.method_defined?(:hq_poll_event_without_input_queue)

      Bubbletea::Program.class_eval do
        alias_method :hq_poll_event_without_input_queue, :poll_event

        def poll_event(timeout_ms)
          @hq_pending_events ||= []
          # Preserve the public poll_event contract: callers still receive one
          # event per call, but no parsed events from a multi-byte read are lost.
          return @hq_pending_events.shift if @hq_pending_events.any?

          raw = read_raw_input(timeout_ms)
          return nil if raw.nil? || raw.empty?

          events, @hq_paste_buffer = HQ::BubbleteaInput.parse_raw(raw, paste_buffer: @hq_paste_buffer)
          @hq_pending_events.concat(events)
          @hq_pending_events.shift
        end
      end
    end
  end
end
# rubocop:enable Metrics/ModuleLength

HQ::BubbleteaInput.install!
