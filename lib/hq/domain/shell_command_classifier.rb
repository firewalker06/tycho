# frozen_string_literal: true

module HQ
  # Finds blocking waits only where shell grammar can execute a command, without running the source.
  class ShellCommandClassifier
    MAX_DEPTH = 8
    SHELL_EXECUTABLES = %w[sh bash zsh dash ksh].freeze
    CONTROL_OPERATORS = %w[& && ( ) ; ;; ;& ;;& <newline> | |& || { }].freeze
    REDIRECT_OPERATORS = %w[< << <<- <<< <& <> > >> >& >| &> &>>].freeze
    OPERATORS = (CONTROL_OPERATORS.reject { |item| item == "<newline>" } + REDIRECT_OPERATORS)
                .sort_by { |item| -item.length }.freeze
    SUDO_OPTIONS_WITH_VALUE = %w[
      -C --close-from -D --chdir -g --group -h --host -p --prompt -R --chroot
      -r --role -t --type -T --command-timeout -u --user
    ].freeze
    ENV_OPTIONS_WITH_VALUE = %w[-C --chdir -S --split-string -u --unset].freeze
    EXEC_OPTIONS_WITH_VALUE = %w[-a].freeze
    NICE_OPTIONS_WITH_VALUE = %w[-n --adjustment].freeze
    TIME_OPTIONS_WITH_VALUE = %w[-f --format -o --output].freeze
    TIMEOUT_OPTIONS_WITH_VALUE = %w[-k --kill-after -s --signal].freeze
    NON_EXECUTING_WRAPPER_OPTIONS = {
      "command" => %w[-v -V],
      "env" => %w[--help --version],
      "nice" => %w[--help --version],
      "nohup" => %w[--help --version],
      "setsid" => %w[--help --version],
      "sudo" => %w[-l -V -v --list --validate --version],
      "time" => %w[--help --version],
      "timeout" => %w[--help --version],
      "gtimeout" => %w[--help --version]
    }.freeze

    Token = Struct.new(
      :type, :value, :control_eligible, :assignment_eligible, :substitutions,
      keyword_init: true
    )
    Substitution = Struct.new(:source, :functions, keyword_init: true)
    Heredoc = Struct.new(:delimiter, :strip_tabs, :expand, :operator_offset, :body, keyword_init: true)

    class WordBuffer
      attr_reader :value

      def initialize
        clear
      end

      def append(text, literal: true)
        @control_eligible &&= literal
        @assignment_eligible = false if !literal && !@equals_seen
        @value << text.to_s
        @equals_seen ||= literal && text.to_s.include?("=")
      end

      alias << append

      def add_substitutions(items)
        @substitutions.concat(Array(items))
      end

      def empty?
        @value.empty?
      end

      def match?(pattern)
        @value.match?(pattern)
      end

      def to_token
        Token.new(
          type: :word,
          value: @value.dup,
          control_eligible: @control_eligible,
          assignment_eligible: @assignment_eligible,
          substitutions: @substitutions.dup
        )
      end

      def clear
        @value = +""
        @control_eligible = true
        @assignment_eligible = true
        @equals_seen = false
        @substitutions = []
      end
    end

    class CommandParser
      SEPARATORS = %w[& && ; <newline> | |& ||].freeze
      ARM_TERMINATORS = %w[;; ;& ;;&].freeze

      Result = Struct.new(:commands, :substitutions, keyword_init: true)

      def initialize(tokens, functions: {}, depth: 0, active_functions: [])
        @tokens = tokens
        @index = 0
        @commands = []
        @substitutions = []
        @functions = functions
        @depth = depth
        @active_functions = active_functions
      end

      def parse
        parse_list
        Result.new(commands: @commands, substitutions: @substitutions)
      end

      private

      def parse_list(stop_words: [], stop_operators: [])
        loop do
          consume_separators
          break if finished? || stop?(stop_words, stop_operators)

          parse_command
          consume_separators
          break if stop?(stop_words, stop_operators)
        end
      end

      def parse_command
        if operator?("(")
          parse_subshell
        elsif operator?("{")
          advance
          parse_list(stop_operators: ["}"])
          advance if operator?("}")
        elsif control_word?("if")
          parse_if
        elsif control_word?("while") || control_word?("until")
          parse_loop
        elsif control_word?("for") || control_word?("select")
          parse_for
        elsif control_word?("case")
          parse_case
        elsif control_word?("function")
          parse_function(keyword: true)
        elsif function_definition?
          parse_function(keyword: false)
        elsif control_word?("time")
          parse_time
        elsif control_word?("!") || control_word?("coproc")
          advance
          parse_command
        else
          parse_simple_command
        end
      end

      def parse_if
        advance
        parse_list(stop_words: ["then"])
        advance if control_word?("then")
        parse_list(stop_words: %w[elif else fi])
        while control_word?("elif")
          advance
          parse_list(stop_words: ["then"])
          advance if control_word?("then")
          parse_list(stop_words: %w[elif else fi])
        end
        if control_word?("else")
          advance
          parse_list(stop_words: ["fi"])
        end
        advance if control_word?("fi")
      end

      def parse_loop
        advance
        parse_list(stop_words: ["do"])
        advance if control_word?("do")
        parse_list(stop_words: ["done"])
        advance if control_word?("done")
      end

      def parse_for
        advance
        advance until finished? || control_word?("do")
        advance if control_word?("do")
        parse_list(stop_words: ["done"])
        advance if control_word?("done")
      end

      def parse_case
        advance
        advance until finished? || control_word?("in")
        advance if control_word?("in")
        loop do
          consume_separators
          break if finished? || control_word?("esac")

          advance until finished? || operator?(")")
          advance if operator?(")")
          parse_list(stop_words: ["esac"], stop_operators: ARM_TERMINATORS)
          advance if ARM_TERMINATORS.any? { |item| operator?(item) }
        end
        advance if control_word?("esac")
      end

      def parse_function(keyword:)
        advance if keyword
        name = current&.value if word?
        advance if word?
        if operator?("(") && operator?(")", offset: 1)
          advance
          advance
        end
        advance while current&.type == :operator && SEPARATORS.include?(current.value)
        body = extract_compound_command
        @functions[name] = body if name && body
      end

      def parse_time
        advance
        if word? && current.value.start_with?("-") && current.value != "-p"
          parse_simple_command(expand_functions: false, record_command: false)
          return
        end

        advance if word? && current.value == "-p"
        parse_command unless finished? || control_operator?
      end

      def parse_simple_command(expand_functions: true, record_command: true)
        command = []
        skip_redirect_target = false
        until finished? || control_operator?
          token = current
          if token.type == :operator && REDIRECT_OPERATORS.include?(token.value)
            skip_redirect_target = true
          elsif skip_redirect_target
            skip_redirect_target = false
          elsif command.empty? && token.assignment_eligible && assignment_word?(token.value)
            nil
          elsif token.type == :word
            command << token.value
          end
          advance
        end
        if command.empty?
          advance unless finished?
        elsif expand_functions && @functions.key?(command.first)
          expand_function(command.first)
        elsif record_command
          @commands << command
        end
      end

      def extract_compound_command
        opener = current&.value
        closer = { "{" => "}", "(" => ")" }[opener]
        return nil unless closer

        start = @index
        depth = 0
        while (token = current)
          if token.type == :operator
            depth += 1 if token.value == opener
            depth -= 1 if token.value == closer
          end
          @index += 1
          return @tokens[start...@index] if depth.zero?
        end
        @tokens[start...@index]
      end

      def parse_subshell
        outer_functions = @functions
        @functions = outer_functions.dup
        advance
        parse_list(stop_operators: [")"])
        advance if operator?(")")
      ensure
        @functions = outer_functions
      end

      def expand_function(name)
        return if @depth >= MAX_DEPTH || @active_functions.include?(name)

        result = self.class.new(
          @functions.fetch(name),
          functions: @functions,
          depth: @depth + 1,
          active_functions: @active_functions + [name]
        ).parse
        @commands.concat(result.commands)
        @substitutions.concat(result.substitutions)
      end

      def consume_separators
        advance while current&.type == :operator && SEPARATORS.include?(current.value)
      end

      def stop?(words, operators)
        words.any? { |item| control_word?(item) } || operators.any? { |item| operator?(item) }
      end

      def function_definition?
        word? && operator?("(", offset: 1) && operator?(")", offset: 2)
      end

      def assignment_word?(word)
        word.match?(/\A[A-Za-z_][A-Za-z0-9_]*(?:\+)?=/)
      end

      def control_word?(value)
        token = current
        token&.type == :word && token.control_eligible && token.value == value
      end

      def control_operator?
        current&.type == :operator && CONTROL_OPERATORS.include?(current.value)
      end

      def operator?(value, offset: 0)
        token = @tokens[@index + offset]
        token&.type == :operator && token.value == value
      end

      def word?
        current&.type == :word
      end

      def current
        @tokens[@index]
      end

      def advance
        Array(current&.substitutions).each do |source|
          @substitutions << Substitution.new(source:, functions: @functions.dup)
        end
        @index += 1
      end

      def finished?
        @index >= @tokens.length
      end
    end

    def initialize(blocking_commands:)
      @blocking_commands = Array(blocking_commands).map { |item| item.to_s.downcase }.freeze
    end

    def blocking_wait?(source)
      blocking_wait_internal?(source.to_s, depth: 0, functions: {})
    rescue ArgumentError
      false
    end

    private

    def blocking_wait_internal?(source, depth:, functions: {})
      return false if depth > MAX_DEPTH

      masked_source, heredoc_substitutions = mask_heredoc_bodies(source)
      parsed = CommandParser.new(
        lex(masked_source, heredoc_substitutions:),
        functions: functions.dup,
        depth:
      ).parse
      return true if parsed.commands.any? { |command| blocking_command?(command, depth:) }

      parsed.substitutions.any? do |nested|
        blocking_wait_internal?(nested.source, depth: depth + 1, functions: nested.functions)
      end
    end

    def assignment_word?(word)
      word.match?(/\A[A-Za-z_][A-Za-z0-9_]*(?:\+)?=/)
    end

    def blocking_command?(tokens, depth:)
      result = tokens.dup
      loop do
        executable = File.basename(result.first.to_s).downcase
        return false if executable.empty?
        return false if non_executing_wrapper_invocation?(executable, result.drop(1))

        case executable
        when "env"
          result.shift
          consume_options!(result, ENV_OPTIONS_WITH_VALUE)
          result.shift while assignment_word?(result.first.to_s)
        when "sudo"
          result.shift
          consume_options!(result, SUDO_OPTIONS_WITH_VALUE)
        when "command"
          result.shift
          consume_options!(result, [])
        when "exec"
          result.shift
          consume_options!(result, EXEC_OPTIONS_WITH_VALUE)
        when "nohup", "setsid"
          result.shift
          consume_options!(result, [])
        when "nice"
          result.shift
          consume_options!(result, NICE_OPTIONS_WITH_VALUE)
        when "time"
          result.shift
          consume_options!(result, TIME_OPTIONS_WITH_VALUE)
        when "timeout", "gtimeout"
          result.shift
          consume_options!(result, TIMEOUT_OPTIONS_WITH_VALUE)
          result.shift
        else
          if SHELL_EXECUTABLES.include?(executable)
            command_index = result.index { |item| item == "-c" || item.match?(/\A-[a-z]*c[a-z]*\z/i) }
            return false unless command_index && result[command_index + 1]

            return blocking_wait_internal?(result[command_index + 1], depth: depth + 1)
          end

          return @blocking_commands.include?(executable) || executable.casecmp("Start-Sleep").zero?
        end
      end
    end

    def non_executing_wrapper_invocation?(executable, arguments)
      options = NON_EXECUTING_WRAPPER_OPTIONS[executable]
      return false unless options

      arguments.take_while { |argument| argument.start_with?("-") && argument != "--" }.any? do |argument|
        options.include?(argument.split("=", 2).first)
      end
    end

    def consume_options!(tokens, options_with_value)
      loop do
        token = tokens.first.to_s
        break if token.empty?
        if token == "--"
          tokens.shift
          break
        end
        break unless token.start_with?("-") && token != "-"

        option = tokens.shift
        option_name = option.split("=", 2).first
        tokens.shift if options_with_value.include?(option_name) && !option.include?("=")
      end
    end

    def lex(source, heredoc_substitutions: {})
      tokens = []
      word = WordBuffer.new
      index = 0
      while index < source.length
        character = source[index]
        if character == "\n" || character == "\r"
          append_word!(tokens, word)
          tokens << Token.new(type: :operator, value: "<newline>")
          index += source[index, 2] == "\r\n" ? 2 : 1
          next
        end
        if character.match?(/[ \t]/)
          append_word!(tokens, word)
          index += 1
          next
        end
        if character == "#" && word.empty?
          append_word!(tokens, word)
          index = source.index("\n", index) || source.length
          next
        end
        if character == "'"
          value, index = read_single_quoted(source, index)
          word.append(value, literal: false)
          next
        end
        if character == '"'
          value, nested, index = read_double_quoted(source, index)
          word.append(value, literal: false)
          word.add_substitutions(nested)
          next
        end
        if source[index, 3] == "$(("
          value, index = read_parenthesized(source, index + 1)
          word.add_substitutions(embedded_substitutions(value))
          word.append("__arithmetic__", literal: false)
          next
        end
        if source[index, 2] == "$("
          value, index = read_parenthesized(source, index + 1)
          word.add_substitutions(value)
          word.append("__substitution__", literal: false)
          next
        end
        if character == "`"
          value, index = read_backtick(source, index)
          word.add_substitutions(value)
          word.append("__substitution__", literal: false)
          next
        end
        if source[index, 2] == "((" && word.empty?
          value, index = read_parenthesized(source, index)
          word.add_substitutions(embedded_substitutions(value))
          word.append("__arithmetic_command__", literal: false)
          next
        end
        if character == "(" && assignment_word?(word)
          value, index = read_parenthesized(source, index)
          word.add_substitutions(embedded_substitutions(value))
          word.append("__array__", literal: false)
          next
        end
        if %w[< >].include?(character) && source[index + 1] == "("
          value, index = read_parenthesized(source, index + 1)
          word.add_substitutions(value)
          word.append("__substitution__", literal: false)
          next
        end
        if character == "\\"
          word.append(source[index + 1].to_s, literal: false)
          index += source[index + 1] ? 2 : 1
          next
        end

        operator = operator_at(source, index)
        if operator
          word.clear if REDIRECT_OPERATORS.include?(operator) && word.match?(/\A\d+\z/)
          append_word!(tokens, word)
          tokens << Token.new(
            type: :operator,
            value: operator,
            substitutions: heredoc_substitutions.fetch(index, [])
          )
          index += operator.length
          next
        end

        word << character
        index += 1
      end
      append_word!(tokens, word)
      tokens
    end

    def append_word!(tokens, word)
      return if word.empty?

      tokens << word.to_token
      word.clear
    end

    def operator_at(source, index)
      OPERATORS.find { |operator| source[index, operator.length] == operator }
    end

    def read_single_quoted(source, index)
      closing = source.index("'", index + 1)
      return [source[(index + 1)..].to_s, source.length] unless closing

      [source[(index + 1)...closing], closing + 1]
    end

    def read_double_quoted(source, index)
      value = +""
      substitutions = []
      index += 1
      while index < source.length
        character = source[index]
        return [value, substitutions, index + 1] if character == '"'
        if character == "\\"
          value << source[index + 1].to_s
          index += source[index + 1] ? 2 : 1
        elsif source[index, 3] == "$(("
          nested, index = read_parenthesized(source, index + 1)
          substitutions.concat(embedded_substitutions(nested))
          value << "__arithmetic__"
        elsif source[index, 2] == "$("
          nested, index = read_parenthesized(source, index + 1)
          substitutions << nested
          value << "__substitution__"
        elsif character == "`"
          nested, index = read_backtick(source, index)
          substitutions << nested
          value << "__substitution__"
        else
          value << character
          index += 1
        end
      end
      [value, substitutions, index]
    end

    def embedded_substitutions(source)
      substitutions = []
      index = 0
      while index < source.length
        character = source[index]
        if character == "'"
          _value, index = read_single_quoted(source, index)
        elsif character == '"'
          _value, nested, index = read_double_quoted(source, index)
          substitutions.concat(nested)
        elsif source[index, 3] == "$(("
          nested, index = read_parenthesized(source, index + 1)
          substitutions.concat(embedded_substitutions(nested))
        elsif source[index, 2] == "$("
          nested, index = read_parenthesized(source, index + 1)
          substitutions << nested
        elsif character == "`"
          nested, index = read_backtick(source, index)
          substitutions << nested
        elsif %w[< >].include?(character) && source[index + 1] == "("
          nested, index = read_parenthesized(source, index + 1)
          substitutions << nested
        elsif character == "\\"
          index += source[index + 1] ? 2 : 1
        else
          index += 1
        end
      end
      substitutions
    end

    def read_parenthesized(source, opening_index, mask_heredocs: true)
      depth = 1
      value_start = opening_index + 1
      index = value_start
      scanned = if mask_heredocs
                  masked, = mask_heredoc_bodies(source[value_start..].to_s)
                  source[0...value_start].to_s + masked
                else
                  source
                end
      quote = nil
      escaped = false
      while index < scanned.length
        character = scanned[index]
        if escaped
          escaped = false
        elsif quote
          if quote == '"' && character == "\\"
            escaped = true
          elsif character == quote
            quote = nil
          end
        else
          case character
          when "'", '"'
            quote = character
          when "\\"
            escaped = true
          when "#"
            if index == value_start || scanned[index - 1].match?(/[\s;|&()]/)
              newline = scanned.index("\n", index)
              index = newline || scanned.length
              next
            end
          when "("
            depth += 1
          when ")"
            depth -= 1
            return [source[value_start...index], index + 1] if depth.zero?
          end
        end
        index += 1
      end
      [source[value_start..].to_s, source.length]
    end

    def read_backtick(source, index)
      value = +""
      index += 1
      while index < source.length
        character = source[index]
        if character == "\\" && source[index + 1]
          value << source[index + 1]
          index += 2
        elsif character == "`"
          return [value, index + 1]
        else
          value << character
          index += 1
        end
      end
      [value, index]
    end

    def mask_heredoc_bodies(source)
      pending = []
      substitutions = {}
      offset = 0
      masked = source.lines(chomp: false).map do |line|
        result = if pending.any?
                   heredoc = pending.first
                   candidate = line.sub(/\r?\n\z/, "")
                   candidate = candidate.sub(/\A\t+/, "") if heredoc.strip_tabs
                   if candidate == heredoc.delimiter
                     if heredoc.expand
                       substitutions[heredoc.operator_offset] = heredoc_substitutions(heredoc.body)
                     end
                     pending.shift
                   else
                     heredoc.body << line
                   end
                   mask_line(line)
                 else
                   pending.concat(heredoc_declarations(line, base_offset: offset))
                   line
                 end
        offset += line.length
        result
      end.join
      [masked, substitutions]
    end

    def mask_line(line)
      line.gsub(/[^\r\n]/, " ")
    end

    def heredoc_declarations(line, base_offset: 0)
      declarations = []
      index = 0
      quote = nil
      escaped = false
      while index < line.length
        character = line[index]
        if escaped
          escaped = false
        elsif quote
          if quote == '"' && character == "\\"
            escaped = true
          elsif character == quote
            quote = nil
          end
        elsif character == "\\"
          escaped = true
        elsif %w[' "].include?(character)
          quote = character
        elsif character == "#" && (index.zero? || line[index - 1].match?(/[\s;|&()]/))
          break
        elsif line[index, 3] == "$(("
          _value, index = read_parenthesized(line, index + 1, mask_heredocs: false)
          next
        elsif line[index, 2] == "(("
          _value, index = read_parenthesized(line, index, mask_heredocs: false)
          next
        elsif line[index, 3] != "<<<" && line[index, 2] == "<<"
          operator_offset = base_offset + index
          strip_tabs = line[index, 3] == "<<-"
          index += strip_tabs ? 3 : 2
          index += 1 while line[index]&.match?(/[ \t]/)
          raw, index = read_heredoc_word(line, index)
          delimiter = normalize_heredoc_delimiter(raw)
          unless delimiter.empty?
            declarations << Heredoc.new(
              delimiter:,
              strip_tabs:,
              expand: heredoc_expands?(raw),
              operator_offset:,
              body: +""
            )
          end
          next
        end
        index += 1
      end
      declarations
    end

    def read_heredoc_word(line, index)
      start = index
      quote = nil
      escaped = false
      while index < line.length
        character = line[index]
        if escaped
          escaped = false
        elsif quote
          if quote == '"' && character == "\\"
            escaped = true
          elsif character == quote
            quote = nil
          end
        elsif character == "\\"
          escaped = true
        elsif %w[' "].include?(character)
          quote = character
        elsif character.match?(/[\s;|&()<>]/)
          break
        end
        index += 1
      end
      [line[start...index].to_s, index]
    end

    def normalize_heredoc_delimiter(raw)
      raw.gsub(/\\(.)/, "\\1").delete("'\"")
    end

    def heredoc_expands?(raw)
      !raw.match?(/[\\'\"]/)
    end

    def heredoc_substitutions(source)
      substitutions = []
      index = 0
      while index < source.length
        character = source[index]
        if source[index, 3] == "$(("
          nested, index = read_parenthesized(source, index + 1)
          substitutions.concat(embedded_substitutions(nested))
        elsif source[index, 2] == "$("
          nested, index = read_parenthesized(source, index + 1)
          substitutions << nested
        elsif character == "`"
          nested, index = read_backtick(source, index)
          substitutions << nested
        elsif character == "\\"
          index += source[index + 1] ? 2 : 1
        else
          index += 1
        end
      end
      substitutions
    end
  end
end
