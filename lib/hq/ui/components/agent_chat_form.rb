# frozen_string_literal: true

require "bubbles"
require "json"

require_relative "chat_composer"
require_relative "inquiry_form"
require_relative "../rendering/styles"

module HQ
  module UI
    class AgentChatForm
      MIN_CONTENT_HEIGHT = 6
      SUMMARY_COLLAPSED_HEIGHT = 5

      FOCUS_CONTENT = 0
      FOCUS_SUMMARY = 1
      FOCUS_PROMPT = 2
      FOCUS_SLOTS = 3

      attr_reader :agent, :composer, :viewport, :summary_viewport, :block_viewport, :summary_detail_viewport,
                  :attachments_viewport, :attachments, :selected_attachment_index, :focus_index, :inquiry_form

      def initialize(agent, width: 96, body_height: 24, composer_height: ChatComposer::DEFAULT_MIN_HEIGHT)
        @agent = agent
        @body_height = body_height
        @viewport = Bubbles::Viewport.new(width: width, height: MIN_CONTENT_HEIGHT)
        @summary_viewport = Bubbles::Viewport.new(width: width, height: SUMMARY_COLLAPSED_HEIGHT)
        @block_viewport = Bubbles::Viewport.new(width: width, height: MIN_CONTENT_HEIGHT)
        @summary_detail_viewport = Bubbles::Viewport.new(width: width, height: SUMMARY_COLLAPSED_HEIGHT)
        @attachments_viewport = Bubbles::Viewport.new(width: width, height: SUMMARY_COLLAPSED_HEIGHT)
        @attachments = []
        @selected_attachment_index = 0
        @conversation_blocks = []
        @selected_block_index = 0
        @block_detail_open = false
        @summary_detail_open = false
        @attachments_detail_open = false
        @summary_line_count = 0
        @summary_detail_line_count = 0
        @composer = ChatComposer.new(width: width, height: composer_height)
        @inquiry_form = nil
        @inquiry_signature = nil
        @focus_index = FOCUS_PROMPT
        sync_inquiry!(agent.respond_to?(:latest_inquiry) ? agent.latest_inquiry : nil)
        apply_layout
        focus_current!
      end

      def content
        input_component.content
      end

      def resize(width:, body_height:)
        @body_height = body_height
        @viewport.width = width
        @summary_viewport.width = width
        @block_viewport.width = width
        @summary_detail_viewport.width = width
        @attachments_viewport.width = width
        @composer.width = width
        @inquiry_form&.width = width
        apply_layout
      end

      def sync!(content)
        apply_layout
        @viewport.content = content
      end

      def sync_blocks(blocks, content)
        previous_count = @conversation_blocks.length
        first_sync = previous_count.zero? && @selected_block_index.zero?
        grew = blocks.length > previous_count
        @conversation_blocks = blocks
        @selected_block_index = if (first_sync || grew) && !blocks.empty?
                                  blocks.length - 1
                                else
                                  [[@selected_block_index, blocks.length - 1].min, 0].max
                                end
        sync!(content)
        sync_selected_block_scroll!(anchor: first_sync || grew ? :bottom : :nearest)
        sync_block_detail!
      end

      def sync_summary!(text)
        value = text.to_s
        lines = value.empty? ? [] : value.lines.map(&:chomp)
        @summary_line_count = lines.length
        apply_layout

        display = if !summary_focused? && lines.length > SUMMARY_COLLAPSED_HEIGHT
                    (lines.first(SUMMARY_COLLAPSED_HEIGHT - 1) + ["..."]).join("\n")
                  else
                    value
                  end
        @summary_viewport.content = display
      end

      def sync_summary_detail!(text)
        value = text.to_s
        @summary_detail_line_count = value.empty? ? 0 : value.lines.count
        apply_layout
        @summary_detail_viewport.content = value
      end

      def sync_attachment_items!(attachments)
        @attachments = Array(attachments)
        @selected_attachment_index = if @attachments.empty?
                                       0
                                     else
                                       [[@selected_attachment_index, @attachments.length - 1].min, 0].max
                                     end
        sync_selected_attachment_scroll!
      end

      def sync_attachments!(text, width: nil, height: nil)
        @attachments_viewport.width = width if width
        @attachments_viewport.height = height if height
        @attachments_viewport.content = text.to_s
        sync_selected_attachment_scroll!
      end

      def sync_inquiry!(inquiry)
        signature = inquiry ? JSON.generate(inquiry) : nil
        return if signature == @inquiry_signature

        if inquiry
          @inquiry_form = InquiryForm.new(inquiry, width: @viewport.width)
          @composer.blur_input
        else
          @inquiry_form = nil
        end
        @inquiry_signature = signature
        focus_current!
      end

      def next_focus
        blur_current!
        @focus_index = (@focus_index + 1) % FOCUS_SLOTS
        focus_current!
        apply_layout
      end

      def previous_focus
        blur_current!
        @focus_index = (@focus_index - 1) % FOCUS_SLOTS
        focus_current!
        apply_layout
      end

      def content_focused?
        @focus_index == FOCUS_CONTENT
      end

      def summary_focused?
        @focus_index == FOCUS_SUMMARY
      end

      def prompt_focused?
        @focus_index == FOCUS_PROMPT
      end

      def summary_truncated?
        !summary_focused? && @summary_line_count > SUMMARY_COLLAPSED_HEIGHT
      end

      def summary_scrollable?
        viewport = summary_detail_open? ? @summary_detail_viewport : @summary_viewport
        summary_focused? && viewport.total_line_count > viewport.height
      end

      def open_summary_detail
        @summary_detail_open = true
        @summary_detail_viewport.goto_top
      end

      def close_summary_detail
        @summary_detail_open = false
      end

      def summary_detail_open?
        @summary_detail_open
      end

      def toggle_attachments_detail
        @attachments_detail_open = !@attachments_detail_open
        @attachments_viewport.goto_top if @attachments_detail_open
      end

      def close_attachments_detail
        @attachments_detail_open = false
      end

      def attachments_detail_open?
        @attachments_detail_open
      end

      def selected_attachment
        @attachments[@selected_attachment_index]
      end

      def select_previous_attachment
        return if @attachments.empty?

        @selected_attachment_index = (@selected_attachment_index - 1) % @attachments.length
        sync_selected_attachment_scroll!
      end

      def select_next_attachment
        return if @attachments.empty?

        @selected_attachment_index = (@selected_attachment_index + 1) % @attachments.length
        sync_selected_attachment_scroll!
      end

      def conversation_blocks
        @conversation_blocks
      end

      def selected_block_index
        @selected_block_index
      end

      def selected_block
        @conversation_blocks[@selected_block_index]
      end

      def selected_block_position
        return "Block 0/0" if @conversation_blocks.empty?

        "Block #{@selected_block_index + 1}/#{@conversation_blocks.length}"
      end

      def selected_block_viewport_debug
        return "visible 0/0" if @conversation_blocks.empty?

        visibility = selected_block_visibility
        return "visible 0/0  block #{visibility[:block_height]} lines" if visibility[:visible_count].zero?

        "visible #{visibility[:visible_start]}-#{visibility[:visible_end]}/#{@viewport.height}  block #{visibility[:block_height]} lines"
      end

      def selected_block_diagnostics
        return nil if @conversation_blocks.empty?

        visibility = selected_block_visibility
        "#{Rendering::Styles::MARKERS[:block_count]} #{@selected_block_index + 1}/#{@conversation_blocks.length}  #{Rendering::Styles::MARKERS[:visible_count]} #{visibility[:visible_count]}/#{@viewport.height}"
      end

      def selected_block_detail_diagnostics
        return nil if @conversation_blocks.empty?

        total = @block_viewport.total_line_count
        visible_count = [[total - @block_viewport.y_offset, 0].max, @block_viewport.height].min
        "#{Rendering::Styles::MARKERS[:block_count]} #{@selected_block_index + 1}/#{@conversation_blocks.length}  #{Rendering::Styles::MARKERS[:visible_count]} #{visible_count}/#{@block_viewport.height}"
      end

      def selected_block_visibility
        cursor_line = selected_block&.fetch(:line_offset, nil).to_i
        height = [selected_block&.fetch(:line_height, nil).to_i, 1].max
        viewport_top = @viewport.y_offset
        viewport_bottom = viewport_top + @viewport.height - 1
        block_top = cursor_line
        block_bottom = cursor_line + height - 1
        visible_top = [block_top, viewport_top].max
        visible_bottom = [block_bottom, viewport_bottom].min

        if visible_bottom < visible_top
          return { visible_count: 0, visible_start: 0, visible_end: 0, block_height: height }
        end

        visible_start = visible_top - viewport_top + 1
        visible_end = visible_bottom - viewport_top + 1
        { visible_count: visible_end - visible_start + 1, visible_start:, visible_end:, block_height: height }
      end

      def selected_block_title
        selected_block&.fetch(:detail_title, nil).to_s
      end

      def select_previous_block
        return if @conversation_blocks.empty?

        @selected_block_index = (@selected_block_index - 1) % @conversation_blocks.length
        sync_selected_block_scroll!(anchor: :previous)
        sync_block_detail!
      end

      def select_next_block
        return if @conversation_blocks.empty?

        @selected_block_index = (@selected_block_index + 1) % @conversation_blocks.length
        sync_selected_block_scroll!(anchor: :next)
        sync_block_detail!
      end

      def open_selected_block
        return if selected_block.nil?

        @block_detail_open = true
        @block_viewport.goto_top
        sync_block_detail!
      end

      def select_previous_detail_block
        select_previous_block
        open_selected_block
      end

      def select_next_detail_block
        select_next_block
        open_selected_block
      end

      def close_block_detail
        @block_detail_open = false
      end

      def block_detail_open?
        @block_detail_open
      end

      def sync_block_detail!
        return unless @block_detail_open

        @block_viewport.content = selected_block ? resolve_block_content(selected_block) : ""
      end

      def resolve_block_content(block)
        builder = block[:content_builder]
        if builder
          block[:content] = builder.call.to_s
        elsif !block.key?(:content)
          block[:content] = ""
        end
        block[:content]
      end

      def sync_selected_block_scroll!(anchor: :nearest)
        return if @conversation_blocks.empty?

        block_top = selected_block&.fetch(:line_offset, nil).to_i
        block_height = [selected_block&.fetch(:line_height, nil).to_i, 1].max
        block_bottom = block_top + block_height - 1
        viewport_top = @viewport.y_offset
        viewport_bottom = viewport_top + @viewport.height - 1

        @viewport.y_offset = case anchor
                             when :bottom
                               selected_block_offset_for_bottom_anchor(block_top, block_bottom, block_height)
                             else
                               nearest_selected_block_offset(block_top, block_bottom, block_height,
                                                             viewport_top, viewport_bottom)
                             end
      end

      def sync_selected_attachment_scroll!
        return if @attachments.empty?

        viewport_top = @attachments_viewport.y_offset
        viewport_bottom = viewport_top + @attachments_viewport.height - 1
        if @selected_attachment_index < viewport_top
          @attachments_viewport.y_offset = @selected_attachment_index
        elsif @selected_attachment_index > viewport_bottom
          @attachments_viewport.y_offset = @selected_attachment_index - @attachments_viewport.height + 1
        end
      end

      def prompt_height
        input_component.height
      end

      def content_height
        @viewport.height
      end

      def inquiry_active?
        !@inquiry_form.nil?
      end

      def input_component
        @inquiry_form || @composer
      end

      def skill_picker
        @composer.skill_picker
      end

      def skill_picker_open?
        !inquiry_active? && @composer.skill_picker.open?
      end

      private

      def apply_layout
        max_prompt_height = [@body_height - MIN_CONTENT_HEIGHT, 1].max
        desired = input_component.desired_height(max_prompt_height)
        input_component.height = desired if input_component.respond_to?(:height=)

        summary_height = summary_section_height
        @summary_viewport.height = summary_height if summary_height.positive?
        @summary_detail_viewport.height = [summary_height - 2, 1].max if summary_height.positive?

        available = @body_height - input_component.height - summary_height - section_chrome_height(summary_height)
        @viewport.height = [available, MIN_CONTENT_HEIGHT].max
        @block_viewport.height = [@viewport.height - 2, 1].max
      end

      def section_chrome_height(_summary_height)
        2
      end

      def summary_section_height
        return 0 if @summary_line_count.zero?
        if summary_detail_open?
          max_expanded = [@body_height - input_component.height - MIN_CONTENT_HEIGHT, SUMMARY_COLLAPSED_HEIGHT].max
          return [[@summary_detail_line_count + 2, SUMMARY_COLLAPSED_HEIGHT].max, max_expanded].min
        end
        return [@summary_line_count, SUMMARY_COLLAPSED_HEIGHT].min unless summary_focused?

        max_expanded = [@body_height - input_component.height - MIN_CONTENT_HEIGHT, SUMMARY_COLLAPSED_HEIGHT].max
        [@summary_line_count, max_expanded].min
      end

      def focus_current!
        if prompt_focused?
          input_component.focus_input
        else
          input_component.blur_input
        end
      end

      def blur_current!
        input_component.blur_input if prompt_focused?
      end

      def bottom_aligned_offset(block_bottom)
        [block_bottom - @viewport.height + 1, 0].max
      end

      def selected_block_offset_for_bottom_anchor(block_top, block_bottom, block_height)
        return block_top if block_height >= @viewport.height

        bottom_aligned_offset(block_bottom)
      end

      def nearest_selected_block_offset(block_top, block_bottom, block_height, viewport_top, viewport_bottom)
        return block_top if block_height >= @viewport.height
        return block_top if block_top < viewport_top
        return bottom_aligned_offset(block_bottom) if block_bottom > viewport_bottom

        viewport_top
      end
    end
  end
end
