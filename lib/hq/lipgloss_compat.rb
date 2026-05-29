# frozen_string_literal: true

require "strscan"

module Lipgloss
  VERSION = "tycho-compat"
  BACKEND = :ruby

  ANSI_PATTERN = /\e\[[0-9;]*[A-Za-z]/.freeze
  OSC8_PATTERN = /\e\]8;[^\e]*\e\\/.freeze

  module Position
    TOP = 0.0
    BOTTOM = 1.0
    LEFT = 0.0
    RIGHT = 1.0
    CENTER = 0.5

    module_function

    def resolve(position)
      case position
      when :top, "top" then TOP
      when :bottom, "bottom" then BOTTOM
      when :left, "left" then LEFT
      when :right, "right" then RIGHT
      when :center, "center" then CENTER
      when Numeric then position.to_f
      else TOP
      end
    end
  end

  module Border
    NORMAL = :normal
    ROUNDED = :rounded
    THICK = :thick
    DOUBLE = :double
    ASCII = :ascii
    HIDDEN = :hidden
    BLOCK = :block
  end

  TOP = Position::TOP
  BOTTOM = Position::BOTTOM
  LEFT = Position::LEFT
  RIGHT = Position::RIGHT
  CENTER = Position::CENTER

  NORMAL_BORDER = Border::NORMAL
  ROUNDED_BORDER = Border::ROUNDED
  THICK_BORDER = Border::THICK
  DOUBLE_BORDER = Border::DOUBLE
  HIDDEN_BORDER = Border::HIDDEN
  BLOCK_BORDER = Border::BLOCK
  ASCII_BORDER = Border::ASCII

  NO_TAB_CONVERSION = -1

  module ANSIColor
    COLORS = {
      black: "0",
      red: "1",
      green: "2",
      yellow: "3",
      blue: "4",
      magenta: "5",
      cyan: "6",
      white: "7",
      bright_black: "8",
      bright_red: "9",
      bright_green: "10",
      bright_yellow: "11",
      bright_blue: "12",
      bright_magenta: "13",
      bright_cyan: "14",
      bright_white: "15"
    }.freeze

    module_function

    def resolve(value)
      case value
      when Symbol then COLORS.fetch(value) { value.to_s }
      when Integer then value.to_s
      else value.to_s
      end
    end
  end

  class AdaptiveColor
    attr_reader :light, :dark

    def initialize(light:, dark:)
      @light = light
      @dark = dark
    end

    def to_h
      { light: @light, dark: @dark }
    end
  end

  class CompleteColor
    attr_reader :true_color, :ansi256, :ansi

    def initialize(true_color:, ansi256:, ansi:)
      @true_color = true_color
      @ansi256 = ANSIColor.resolve(ansi256)
      @ansi = ANSIColor.resolve(ansi)
    end

    def to_h
      { true_color: @true_color, ansi256: @ansi256, ansi: @ansi }
    end
  end

  class CompleteAdaptiveColor
    attr_reader :light, :dark

    def initialize(light:, dark:)
      @light = light
      @dark = dark
    end

    def to_h
      { light: @light.to_h, dark: @dark.to_h }
    end
  end

  module_function

  def width(string)
    string.to_s.split("\n", -1).map { |line| visible_width(line) }.max || 0
  end

  def height(string)
    string.to_s.split("\n", -1).length
  end

  def join_horizontal(position, *strings)
    position = Position.resolve(position)
    blocks = strings.map do |string|
      lines = string.to_s.split("\n", -1)
      block_width = lines.map { |line| visible_width(line) }.max || 0
      { lines: lines, width: block_width, height: lines.length }
    end
    max_height = blocks.map { |block| block[:height] }.max || 0

    blocks.each do |block|
      missing = max_height - block[:height]
      top = vertical_offset(missing, position)
      block[:lines] = (Array.new(top, "") + block[:lines] + Array.new(missing - top, "")).map do |line|
        pad_visible(line, block[:width])
      end
    end

    max_height.times.map do |index|
      blocks.map { |block| block[:lines][index].to_s }.join
    end.join("\n")
  end

  def join_vertical(position, *strings)
    position = Position.resolve(position)
    blocks = strings.map { |string| string.to_s.split("\n", -1) }
    max_width = blocks.flatten.map { |line| visible_width(line) }.max || 0

    blocks.map do |lines|
      lines.map { |line| align_line(line, max_width, position) }.join("\n")
    end.join("\n")
  end

  def place(width, height, horizontal, vertical, string, **_opts)
    horizontal = Position.resolve(horizontal)
    vertical = Position.resolve(vertical)
    lines = string.to_s.split("\n", -1)
    block_width = lines.map { |line| visible_width(line) }.max || 0
    missing_height = [height.to_i - lines.length, 0].max
    top = vertical_offset(missing_height, vertical)
    placed = lines.map { |line| place_horizontal(width, horizontal, pad_visible(line, block_width)) }
    blank = " " * width.to_i

    (Array.new(top, blank) + placed + Array.new(missing_height - top, blank)).join("\n")
  end

  def place_horizontal(width, position, string)
    position = Position.resolve(position)
    target = width.to_i
    string.to_s.split("\n", -1).map { |line| align_line(line, target, position) }.join("\n")
  end

  def place_vertical(height, position, string)
    position = Position.resolve(position)
    lines = string.to_s.split("\n", -1)
    missing = [height.to_i - lines.length, 0].max
    top = vertical_offset(missing, position)
    (Array.new(top, "") + lines + Array.new(missing - top, "")).join("\n")
  end

  def visible_width(string)
    stripped = string.to_s.gsub(ANSI_PATTERN, "").gsub(OSC8_PATTERN, "")
    stripped.each_char.sum { |char| double_width_codepoint?(char.ord) ? 2 : 1 }
  end

  def pad_visible(string, target)
    visible = visible_width(string)
    return string.to_s if visible >= target

    "#{string}#{" " * (target - visible)}"
  end

  def align_line(line, target, position)
    visible = visible_width(line)
    missing = [target - visible, 0].max
    left = horizontal_offset(missing, position)
    "#{" " * left}#{line}#{" " * (missing - left)}"
  end

  def horizontal_offset(missing, position)
    return missing if position >= Position::RIGHT
    return (missing / 2.0).floor if position >= Position::CENTER

    0
  end

  def vertical_offset(missing, position)
    return missing if position >= Position::BOTTOM
    return (missing / 2.0).floor if position >= Position::CENTER

    0
  end

  def double_width_codepoint?(codepoint)
    DOUBLE_WIDTH_RANGES.any? { |range| range.cover?(codepoint) }
  end

  DOUBLE_WIDTH_RANGES = [
    0x1100..0x115F,
    0x2E80..0x303E,
    0x3041..0x33FF,
    0x3400..0x4DBF,
    0x4E00..0x9FFF,
    0xA000..0xA4CF,
    0xAC00..0xD7A3,
    0xF900..0xFAFF,
    0xFE30..0xFE4F,
    0xFF00..0xFF60,
    0xFFE0..0xFFE6,
    0x1F300..0x1F64F,
    0x1F680..0x1F6FF,
    0x1F900..0x1F9FF
  ].freeze

  BORDER_CHARS = {
    normal: ["┌", "┐", "└", "┘", "─", "│", "├", "┤", "┬", "┴", "┼"],
    rounded: ["╭", "╮", "╰", "╯", "─", "│", "├", "┤", "┬", "┴", "┼"],
    thick: ["┏", "┓", "┗", "┛", "━", "┃", "┣", "┫", "┳", "┻", "╋"],
    double: ["╔", "╗", "╚", "╝", "═", "║", "╠", "╣", "╦", "╩", "╬"],
    ascii: ["+", "+", "+", "+", "-", "|", "+", "+", "+", "+", "+"],
    hidden: [" ", " ", " ", " ", " ", " ", " ", " ", " ", " ", " "],
    block: ["█", "█", "█", "█", "█", "█", "█", "█", "█", "█", "█"]
  }.freeze

  class Style
    BOOLEAN_ATTRIBUTES = %i[bold italic faint reverse underline blink strikethrough inline].freeze

    attr_reader :attributes

    def initialize(attributes = {})
      @attributes = attributes.dup.freeze
    end

    def render(value = nil)
      text = value.nil? ? @attributes[:string].to_s : value.to_s
      lines = text.split("\n", -1)
      lines = [""] if lines.empty?
      lines = apply_spacing(lines)
      lines = apply_border(lines) if @attributes[:border]
      lines.map { |line| apply_ansi(line) }.join("\n")
    end

    def to_s
      render
    end

    def set_string(value)
      with(string: value.to_s)
    end

    def width(value)
      with(width: value.nil? ? nil : value.to_i)
    end

    def height(value)
      with(height: value.nil? ? nil : value.to_i)
    end

    def max_width(value)
      with(max_width: value.nil? ? nil : value.to_i)
    end

    def max_height(value)
      with(max_height: value.nil? ? nil : value.to_i)
    end

    def get_width
      @attributes[:width]
    end

    def get_height
      @attributes[:height]
    end

    def foreground(value)
      with(foreground: normalize_color(value))
    end

    def background(value)
      with(background: normalize_color(value))
    end

    def get_foreground
      @attributes[:foreground]
    end

    def get_background
      @attributes[:background]
    end

    def border(value = Border::NORMAL, *_positions)
      type = value == true ? Border::NORMAL : value
      with(border: type || Border::NORMAL)
    end

    def border_style(value)
      border(value)
    end

    def border_foreground(value)
      with(border_foreground: normalize_color(value))
    end

    def border_background(value)
      with(border_background: normalize_color(value))
    end

    def border_top(value = true)
      with(border_top: value)
    end

    def border_bottom(value = true)
      with(border_bottom: value)
    end

    def border_left(value = true)
      with(border_left: value)
    end

    def border_right(value = true)
      with(border_right: value)
    end

    def border_top_foreground(value)
      border_foreground(value)
    end

    def border_bottom_foreground(value)
      border_foreground(value)
    end

    def border_left_foreground(value)
      border_foreground(value)
    end

    def border_right_foreground(value)
      border_foreground(value)
    end

    def border_top_background(value)
      border_background(value)
    end

    def border_bottom_background(value)
      border_background(value)
    end

    def border_left_background(value)
      border_background(value)
    end

    def border_right_background(value)
      border_background(value)
    end

    def border_custom(value)
      border(value)
    end

    def padding(*values)
      top, right, bottom, left = expand_box(values)
      with(padding_top: top, padding_right: right, padding_bottom: bottom, padding_left: left)
    end

    def margin(*values)
      top, right, bottom, left = expand_box(values)
      with(margin_top: top, margin_right: right, margin_bottom: bottom, margin_left: left)
    end

    %i[padding margin].each do |prefix|
      %i[top right bottom left].each do |side|
        define_method("#{prefix}_#{side}") do |value|
          with("#{prefix}_#{side}".to_sym => value.to_i)
        end
      end
    end

    def margin_background(value)
      with(margin_background: normalize_color(value))
    end

    def align(*positions)
      horizontal = positions.find { |position| %i[left center right].include?(position) || position.is_a?(Numeric) }
      vertical = positions.find { |position| %i[top bottom].include?(position) }
      with(align_horizontal: horizontal, align_vertical: vertical)
    end

    def align_horizontal(position)
      with(align_horizontal: position)
    end

    def align_vertical(position)
      with(align_vertical: position)
    end

    def tab_width(value)
      with(tab_width: value.to_i)
    end

    def inherit(_style)
      self
    end

    BOOLEAN_ATTRIBUTES.each do |attribute|
      define_method(attribute) do |value = true|
        with(attribute => !!value)
      end

      define_method("#{attribute}?") do
        !!@attributes[attribute]
      end
    end

    def underline_spaces(value = true)
      with(underline_spaces: !!value)
    end

    def strikethrough_spaces(value = true)
      with(strikethrough_spaces: !!value)
    end

    def method_missing(method_name, *args, &block)
      name = method_name.to_s
      if name.start_with?("unset_")
        key = name.delete_prefix("unset_").to_sym
        return with(key => nil)
      end

      super
    end

    def respond_to_missing?(method_name, include_private = false)
      method_name.to_s.start_with?("unset_") || super
    end

    private

    def with(attributes)
      self.class.new(@attributes.merge(attributes))
    end

    def normalize_color(value)
      case value
      when AdaptiveColor then value.dark
      when CompleteColor then value.true_color
      when CompleteAdaptiveColor then value.dark.true_color
      when Symbol, Integer then ANSIColor.resolve(value)
      else value.to_s
      end
    end

    def expand_box(values)
      values = [0] if values.empty?
      values = values.flatten.map(&:to_i)
      case values.length
      when 1 then [values[0], values[0], values[0], values[0]]
      when 2 then [values[0], values[1], values[0], values[1]]
      when 3 then [values[0], values[1], values[2], values[1]]
      else [values[0], values[1], values[2], values[3]]
      end
    end

    def apply_spacing(lines)
      padded = lines.flat_map { |line| wrap_line(add_horizontal_padding(line), content_width) }
      padded = padded.map { |line| content_width ? Lipgloss.pad_visible(line, content_width) : line }
      padded = apply_vertical_padding(padded)
      padded = apply_height(padded)
      apply_margin(padded)
    end

    def add_horizontal_padding(line)
      "#{" " * padding_left}#{line}#{" " * padding_right}"
    end

    def wrap_line(line, width)
      return [line] unless width && width.positive? && Lipgloss.visible_width(line) > width

      scanner = StringScanner.new(line)
      current = +""
      current_width = 0
      lines = []

      until scanner.eos?
        if (sequence = scanner.scan(ANSI_PATTERN))
          current << sequence
          next
        end

        char = scanner.getch
        char_width = Lipgloss.double_width_codepoint?(char.ord) ? 2 : 1
        if current_width.positive? && current_width + char_width > width
          lines << current
          current = +""
          current_width = 0
        end
        current << char
        current_width += char_width
      end

      lines << current
      lines
    end

    def apply_vertical_padding(lines)
      width = content_width || (lines.map { |line| Lipgloss.visible_width(line) }.max || 0)
      blank = " " * width
      Array.new(padding_top, blank) + lines + Array.new(padding_bottom, blank)
    end

    def apply_height(lines)
      target = @attributes[:height]
      return lines unless target && target > lines.length

      width = content_width || (lines.map { |line| Lipgloss.visible_width(line) }.max || 0)
      lines + Array.new(target - lines.length, " " * width)
    end

    def apply_margin(lines)
      top = @attributes.fetch(:margin_top, 0).to_i
      right = @attributes.fetch(:margin_right, 0).to_i
      bottom = @attributes.fetch(:margin_bottom, 0).to_i
      left = @attributes.fetch(:margin_left, 0).to_i
      return lines if [top, right, bottom, left].all?(&:zero?)

      width = lines.map { |line| Lipgloss.visible_width(line) }.max || 0
      blank = " " * (left + width + right)
      Array.new(top, blank) +
        lines.map { |line| "#{" " * left}#{Lipgloss.pad_visible(line, width)}#{" " * right}" } +
        Array.new(bottom, blank)
    end

    def apply_border(lines)
      width = lines.map { |line| Lipgloss.visible_width(line) }.max || 0
      bordered_lines = lines.map { |line| "#{border_char(:vertical)}#{Lipgloss.pad_visible(line, width)}#{border_char(:vertical)}" }
      ["#{border_char(:top_left)}#{border_char(:horizontal) * width}#{border_char(:top_right)}"] +
        bordered_lines +
        ["#{border_char(:bottom_left)}#{border_char(:horizontal) * width}#{border_char(:bottom_right)}"]
    end

    def border_char(name)
      chars = BORDER_CHARS.fetch(@attributes[:border] || Border::NORMAL) { BORDER_CHARS[:normal] }
      index = {
        top_left: 0,
        top_right: 1,
        bottom_left: 2,
        bottom_right: 3,
        horizontal: 4,
        vertical: 5
      }.fetch(name)
      char = chars[index]
      color = @attributes[:border_foreground]
      color ? self.class.new(foreground: color).render(char) : char
    end

    def apply_ansi(line)
      sequence = ansi_sequence
      return line if sequence.empty?

      "#{sequence}#{line}\e[0m"
    end

    def ansi_sequence
      codes = []
      codes << "1" if @attributes[:bold]
      codes << "2" if @attributes[:faint]
      codes << "3" if @attributes[:italic]
      codes << "4" if @attributes[:underline]
      codes << "5" if @attributes[:blink]
      codes << "7" if @attributes[:reverse]
      codes << "9" if @attributes[:strikethrough]
      codes << ansi_color(@attributes[:foreground], foreground: true) if @attributes[:foreground]
      codes << ansi_color(@attributes[:background], foreground: false) if @attributes[:background]
      codes.compact!
      codes.empty? ? "" : "\e[#{codes.join(";")}m"
    end

    def ansi_color(color, foreground:)
      color = normalize_color(color)
      if (rgb = parse_hex_color(color))
        prefix = foreground ? "38" : "48"
        "#{prefix};2;#{rgb.join(";")}"
      elsif color.to_s.match?(/\A\d+\z/)
        prefix = foreground ? "38" : "48"
        "#{prefix};5;#{color}"
      end
    end

    def parse_hex_color(color)
      hex = color.to_s.delete_prefix("#")
      hex = hex.each_char.map { |char| char * 2 }.join if hex.length == 3
      return unless hex.match?(/\A[0-9a-fA-F]{6}\z/)

      hex.scan(/../).map { |component| component.to_i(16) }
    end

    def padding_top
      @attributes.fetch(:padding_top, 0).to_i
    end

    def padding_right
      @attributes.fetch(:padding_right, 0).to_i
    end

    def padding_bottom
      @attributes.fetch(:padding_bottom, 0).to_i
    end

    def padding_left
      @attributes.fetch(:padding_left, 0).to_i
    end

    def content_width
      width = @attributes[:width]
      max_width = @attributes[:max_width]
      width ||= max_width
      width&.to_i
    end
  end

  class Table
    HEADER_ROW = -1

    def initialize
      @headers = []
      @rows = []
      @border = Border::ROUNDED
      @border_style = Style.new
      @style_map = {}
    end

    def headers(values)
      @headers = Array(values).map(&:to_s)
      self
    end

    def rows(values)
      @rows = Array(values).map { |row| Array(row).map(&:to_s) }
      self
    end

    def row(values)
      @rows << Array(values).map(&:to_s)
      self
    end

    def clear_rows
      @rows = []
      self
    end

    def border(value = Border::NORMAL)
      @border = value
      self
    end

    def border_style(value)
      @border_style = value || Style.new
      self
    end

    %i[border_top border_bottom border_left border_right border_header border_row border_column width height offset wrap].each do |name|
      define_method(name) do |*_args|
        self
      end
    end

    def style_func(rows:, columns:, &block)
      raise ArgumentError, "block required" unless block

      @style_map = {}
      columns.times { |column| @style_map[[HEADER_ROW, column]] = block.call(HEADER_ROW, column) }
      rows.times do |row|
        columns.times { |column| @style_map[[row, column]] = block.call(row, column) }
      end
      self
    end

    def render
      matrix = []
      matrix << @headers unless @headers.empty?
      matrix.concat(@rows)
      return "" if matrix.empty?

      columns = matrix.map(&:length).max || 0
      widths = Array.new(columns, 0)
      matrix.each do |row|
        columns.times do |column|
          widths[column] = [widths[column], Lipgloss.visible_width(row[column].to_s)].max
        end
      end

      chars = BORDER_CHARS.fetch(@border) { BORDER_CHARS[:rounded] }
      top = border_join(chars[0], chars[8], chars[1], chars[4], widths)
      header_sep = border_join(chars[6], chars[10], chars[7], chars[4], widths)
      bottom = border_join(chars[2], chars[9], chars[3], chars[4], widths)
      lines = [@border_style.render(top)]
      lines << row_line(@headers, widths, HEADER_ROW, chars) unless @headers.empty?
      lines << @border_style.render(header_sep) unless @headers.empty? || @rows.empty?
      @rows.each_with_index { |row, index| lines << row_line(row, widths, index, chars) }
      lines << @border_style.render(bottom)
      lines.join("\n")
    end

    def to_s
      render
    end

    private

    def border_join(left, joint, right, horizontal, widths)
      "#{left}#{widths.map { |width| horizontal * width }.join(joint)}#{right}"
    end

    def row_line(row, widths, row_index, chars)
      cells = widths.each_with_index.map do |width, column|
        value = Lipgloss.pad_visible(row[column].to_s, width)
        style = @style_map[[row_index, column]]
        style ? style.render(value) : value
      end
      "#{@border_style.render(chars[5])}#{cells.join(@border_style.render(chars[5]))}#{@border_style.render(chars[5])}"
    end
  end

  class List
    def initialize
      @enumerator = :bullet
      @enumerator_style = Style.new
      @item_style = Style.new
      @items = []
    end

    def enumerator(value)
      @enumerator = value
      self
    end

    def enumerator_style(value)
      @enumerator_style = value || Style.new
      self
    end

    def item_style(value)
      @item_style = value || Style.new
      self
    end

    def items(values)
      @items = Array(values)
      self
    end

    def render
      @items.each_with_index.map do |item, index|
        marker = @enumerator == :arabic ? "#{index + 1}." : "•"
        marker = @enumerator_style.render(marker)
        lines = @item_style.render(item.to_s).split("\n", -1)
        first = "#{marker} #{lines.first}"
        rest = lines.drop(1).map { |line| "  #{line}" }
        ([first] + rest).join("\n")
      end.join("\n")
    end
  end

  module ColorBlend
    module_function

    def blend(color_a, color_b, ratio)
      ratio = ratio.to_f.clamp(0.0, 1.0)
      a = parse_hex(color_a) || [255, 255, 255]
      b = parse_hex(color_b) || a
      rgb = a.zip(b).map { |start, finish| (start + ((finish - start) * ratio)).round }
      format("#%02X%02X%02X", *rgb)
    end

    def blends(color_a, color_b, count, mode: nil)
      count = count.to_i
      return [] if count <= 0
      return [blend(color_a, color_b, 0.5)] if count == 1

      count.times.map { |index| blend(color_a, color_b, index.to_f / (count - 1)) }
    end

    def parse_hex(color)
      hex = color.to_s.delete_prefix("#")
      hex = hex.each_char.map { |char| char * 2 }.join if hex.length == 3
      return unless hex.match?(/\A[0-9a-fA-F]{6}\z/)

      hex.scan(/../).map { |component| component.to_i(16) }
    end
  end

  class Tree; end
end
