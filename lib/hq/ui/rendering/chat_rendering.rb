# frozen_string_literal: true

require "json"
require "rbconfig"

require_relative "../../domain/attachment_normalizer"

module HQ
  module UI
    module Rendering
      module ChatRendering
        private

        def agent_chat_content(agent)
          return "No agent selected" unless agent

          blocks = agent_chat_conversation_blocks(agent)
          content = render_chat_conversation_block_list(blocks)
          @agent_chat_form&.sync_blocks(blocks, content)
          content
        end

        def agent_chat_conversation_blocks(agent)
          blocks = AgentChatLog.new(agent).chat_blocks
          items = []
          index = 0

          while index < blocks.length
            block = blocks[index]

            if tool_chat_block?(block)
              group = []
              while index < blocks.length && tool_chat_block?(blocks[index])
                group << blocks[index]
                index += 1
              end
              items << chat_tool_group_item(group)
              next
            end

            if block.kind == :message
              group = []
              signature = chat_message_group_signature(block)
              while index < blocks.length && blocks[index].kind == :message &&
                    chat_message_group_signature(blocks[index]) == signature
                group << blocks[index]
                index += 1
              end
              items << chat_message_group_item(agent, group) unless block.role.to_s == "system"
              next
            end
            index += 1
          end

          items
        end

        def tool_chat_block?(block)
          %i[tool_call tool_result].include?(block.kind)
        end

        def agent_chat_summary_text(agent)
          return nil unless agent&.last_run

          summary_icon = Styles::ICONS[:summary]
          summary_width = [bubble_content_width - 2, 10].max
          first_line = agent.last_summary.to_s.lines.map(&:strip).find { |line| !line.empty? }.to_s
          return nil if first_line.empty?

          summary = "#{summary_icon} #{Bubbles::ANSI.cut_string(first_line, 0, summary_width)}"
          summary_style.render(fade_token_usage(summary))
        end

        def render_agent_chat_summary_block(summary_text)
          return nil if summary_text.to_s.empty?

          @agent_chat_form.summary_viewport.view
        end

        def indent_block(block, spaces)
          return block if block.nil? || spaces <= 0

          pad = " " * spaces
          block.to_s.lines.map { |line| "#{pad}#{line.chomp}" }.join("\n")
        end

        def agent_chat_prompt_hint
          base = if @agent_chat_form.summary_focused?
                   scroll_suffix = @agent_chat_form.summary_scrollable? ? "  #{Styles::MARKERS[:bullet_sep]}  #{Styles::KEYS[:arrow_up]}/#{Styles::KEYS[:arrow_down]}: scroll" : ""
                   "#{Styles::KEYS[:tab]}: focus sections#{scroll_suffix}  #{Styles::MARKERS[:bullet_sep]}  esc: close"
                 elsif @agent_chat_form.content_focused?
                   if @agent_chat_form.block_detail_open?
                     "#{Styles::KEYS[:arrow_left]}/#{Styles::KEYS[:arrow_right]}: select block  #{Styles::MARKERS[:bullet_sep]}  enter/esc: close block  #{Styles::MARKERS[:bullet_sep]}  j/k #{Styles::KEYS[:arrow_up]}/#{Styles::KEYS[:arrow_down]}: scroll"
                   else
                     "j/k or #{Styles::KEYS[:arrow_left]}/#{Styles::KEYS[:arrow_right]}: select block  #{Styles::MARKERS[:bullet_sep]}  enter: open block  #{Styles::MARKERS[:bullet_sep]}  R: rebuild  #{Styles::MARKERS[:bullet_sep]}  esc: close"
                   end
                 elsif @agent_chat_form.summary_focused? && @agent_chat_form.summary_detail_open?
                   "enter/esc: close summary  #{Styles::MARKERS[:bullet_sep]}  j/k #{Styles::KEYS[:arrow_up]}/#{Styles::KEYS[:arrow_down]}: scroll"
                 elsif @agent_chat_form.inquiry_active?
                   "#{Styles::KEYS[:tab]}: focus sections  #{Styles::MARKERS[:bullet_sep]}  enter: next  #{Styles::MARKERS[:bullet_sep]}  #{Styles::KEYS[:ctrl]}P: prev  #{Styles::MARKERS[:bullet_sep]}  #{Styles::KEYS[:shift]}Enter: newline  #{Styles::MARKERS[:bullet_sep]}  space: toggle  #{Styles::MARKERS[:bullet_sep]}  #{Styles::KEYS[:ctrl]}S: submit  #{Styles::MARKERS[:bullet_sep]}  esc: close"
                 else
                   "#{Styles::KEYS[:tab]}: focus sections  #{Styles::MARKERS[:bullet_sep]}  #{Styles::KEYS[:shift]}Enter/#{Styles::KEYS[:ctrl]}J newline  #{Styles::MARKERS[:bullet_sep]}  enter: send  #{Styles::MARKERS[:bullet_sep]}  esc: close"
                 end

          base = "#{Styles::KEYS[:ctrl]}A: attachments  #{Styles::MARKERS[:bullet_sep]}  #{base}"
          @agent_chat_form.summary_truncated? ? "#{base}  #{Styles::MARKERS[:bullet_sep]}  #{Styles::KEYS[:tab]} to expand summary" : base
        end

        def agent_chat_state_line(agent)
          return nil unless agent&.last_run

          status = agent.respond_to?(:effective_status) ? agent.effective_status : agent.last_run.status
          label = agent.respond_to?(:last_result_label) ? agent.last_result_label : status
          status_icon = agent_status_icon(status)

          state_prefix = agent.running? ? "#{@spinner.view} " : ""
          state_text = Bubbles::ANSI.cut_string("#{state_prefix}#{status_icon} #{label}", 0, bubble_content_width)
          status_style_for(status).render(state_text)
        end

        ATTACHMENT_ICONS = {
          "file" => "\u{F0219}",
          "document" => "\u{F0219}",
          "link" => "\uF0C1",
          "image" => "\uF1C5"
        }.freeze

        def agent_chat_attachments(agent)
          agent.respond_to?(:attachments) ? agent.attachments : []
        end

        def attachment_compact_summary(attachments)
          items = Array(attachments)
          return nil if items.empty?

          counts = Hash.new(0)
          items.each do |attachment|
            counts[attachment_kind(attachment)] += 1
          end
          parts = %w[file link].filter_map do |kind|
            count = counts[kind]
            count.positive? ? "#{attachment_kind_icon(kind)} #{count}" : nil
          end
          parts.empty? ? nil : parts.join(" ")
        end

        def agent_chat_attachments_text(attachments, selected_index: 0, width:)
          items = Array(attachments)
          return dim_style.render("No attachments yet") if items.empty?

          inner_width = [width.to_i, 10].max
          items.map.with_index(1) do |attachment, index|
            render_attachment_row(
              attachment,
              index:,
              selected: index - 1 == selected_index.to_i,
              width: inner_width
            )
          end.join("\n")
        end

        def render_attachment_row(attachment, index:, selected:, width:)
          kind = attachment_kind(attachment)
          icon = attachment_kind_icon(kind)
          title = attachment["title"].to_s.strip
          target = AttachmentNormalizer.attachment_target(attachment)
          title = target if title.empty?

          marker = selected ? Styles::MARKERS[:cursor] : " "
          label_width = [width - 9, 1].max
          label = Bubbles::ANSI.cut_string(title.empty? ? "Untitled attachment" : title, 0, label_width)
          row = " #{marker} #{index}. #{icon} #{label}"
          selected ? selected_style.render(pad_visible(row, width)) : row
        end

        def attachment_kind(attachment)
          return "link" if AttachmentNormalizer.link_attachment?(attachment)

          "file"
        end

        def attachment_kind_icon(kind)
          ATTACHMENT_ICONS[kind.to_s] || ATTACHMENT_ICONS.fetch("link")
        end

        def render_chat_block(agent, block, show_header: true)
          role = block.role.to_s
          content = block.content.to_s

          case role
          when "user"
            wrapped = fade_token_usage(format_chat_message_content(content, role))
            name_tag = user_name_tag_style.render("You")
            body = user_message_style.render(wrapped)
            rendered = show_header ? "#{name_tag}\n#{body}" : body
            align_chat_bubble(chat_message_style.render(rendered))
          when "assistant"
            wrapped = fade_token_usage(format_chat_message_content(content, role))
            name_tag = assistant_name_tag_style.render(agent_display_name(agent))
            body = assistant_message_style.render(wrapped)
            rendered = show_header ? "#{name_tag}\n#{body}" : body
            align_chat_bubble(chat_message_style.render(rendered))
          else
            prefix = show_header ? "#{role.upcase} " : ""
            system_note(chat_message_style.render(wrap_text("#{prefix}#{content}", bubble_content_width)))
          end
        end

        def render_chat_summary(content)
          text = content.to_s.strip
          text = text.sub(/\A\(/, "").sub(/\)\z/, "") if text.start_with?("(") && text.end_with?(")")
          prefixed = "#{Styles::MARKERS[:cursor]} #{text}"
          system_note(chat_message_style.render(wrap_text(prefixed, bubble_content_width)))
        end

        def render_chat_tool_block(block, show_header: true)
          label = if block.kind == :tool_result
                    "Tool result"
                  else
                    tool_block_label(block)
                  end

          body = block.content.to_s.strip
          body = "(empty)" if body.empty?
          inner_width = [bubble_content_width, 10].max
          wrapped_body = wrap_text(body, inner_width)
          label_style = block.kind == :tool_result ? tool_result_label_style : tool_call_label_style
          content = []
          content << label_style.render(label) if show_header
          content << tool_call_body_style.render(wrapped_body.lines.map(&:chomp).join("\n"))
          content = content.join("\n")
          system_note(chat_message_style.render(content))
        end

        def render_chat_message_detail_block(block)
          role = block.role.to_s

          case role
          when "user"
            style = inquiry_response_message?(block) ? inquiry_message_style : user_message_style
            style.render(render_message_detail_with_attachments(block, render_user_detail(block.content.to_s)))
          when "assistant"
            assistant_message_style.render(render_message_detail_with_attachments(block, render_markdown(block.content.to_s)))
          else
            system_message_style.render(
              render_message_detail_with_attachments(block, wrap_text(block.content.to_s, bubble_content_width))
            )
          end
        end

        def render_message_detail_with_attachments(block, body)
          attachments = chat_block_attachments(block)
          return body if attachments.empty?

          [body, render_chat_message_attachments(attachments)].reject(&:empty?).join("\n\n")
        end

        def render_chat_message_attachments(attachments)
          width = [bubble_content_width, 10].max
          rows = attachments.map.with_index(1) do |attachment, index|
            render_attachment_row(attachment, index:, selected: false, width:)
          end
          ([dim_style.render("Attachments")] + rows).join("\n")
        end

        def chat_block_attachments(block)
          metadata = block.respond_to?(:metadata) ? block.metadata : nil
          return [] unless metadata.is_a?(Hash)

          Array(metadata["attachments"]).select do |attachment|
            attachment.is_a?(Hash) &&
              (!attachment["title"].to_s.strip.empty? || !AttachmentNormalizer.attachment_target(attachment).empty?)
          end
        end

        def render_user_detail(content)
          formatted = format_json_object_message(content)
          return formatted if formatted

          render_markdown(content)
        end

        GLAMOUR_CACHE = {}
        GLAMOUR_PENDING = {}
        GLAMOUR_MUTEX = Mutex.new
        GLAMOUR_CACHE_LIMIT = 256
        GLAMOUR_PLACEHOLDER = "Rendering markdown…"

        def self.glamour_render_pending?
          GLAMOUR_MUTEX.synchronize { !GLAMOUR_PENDING.empty? }
        end

        def render_markdown(content)
          faded = fade_token_usage(content.to_s)
          width = [bubble_content_width, 10].max
          key = [width, faded]

          cached = GLAMOUR_MUTEX.synchronize { GLAMOUR_CACHE[key] }
          return cached if cached

          if HQ.env("GLAMOUR_SYNC") == "1"
            perform_glamour_render(faded, width, key)
            return GLAMOUR_MUTEX.synchronize { GLAMOUR_CACHE[key] } || wrap_text(content.to_s, width)
          end

          GLAMOUR_MUTEX.synchronize do
            unless GLAMOUR_PENDING[key]
              GLAMOUR_PENDING[key] = true
              Thread.new { perform_glamour_render(faded, width, key) }
            end
          end

          GLAMOUR_PLACEHOLDER
        rescue StandardError => e
          HQ.logger.warn("ChatRendering") { "Glamour dispatch failed: #{e.class}: #{e.message}" } if defined?(HQ) && HQ.respond_to?(:logger)
          wrap_text(content.to_s, [bubble_content_width, 10].max)
        end

        WORKER_PATH = File.expand_path("../../../../bin/worker", __dir__)

        def perform_glamour_render(text, width, key)
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          rendered = glamour_subprocess_render(text, width)
          elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(2)
          HQ.logger.debug("ChatRendering") { "render_markdown subprocess done bytes=#{text.bytesize} width=#{width} elapsed_ms=#{elapsed_ms} out_bytes=#{rendered.bytesize}" }

          GLAMOUR_MUTEX.synchronize do
            GLAMOUR_CACHE.shift while GLAMOUR_CACHE.size >= GLAMOUR_CACHE_LIMIT
            GLAMOUR_CACHE[key] = rendered
            GLAMOUR_PENDING.delete(key)
          end
        rescue StandardError => e
          HQ.logger.warn("ChatRendering") { "Glamour render failed: #{e.class}: #{e.message}" }
          GLAMOUR_MUTEX.synchronize { GLAMOUR_PENDING.delete(key) }
        end

        def glamour_subprocess_render(text, width)
          IO.popen([RbConfig.ruby, WORKER_PATH, "--type", "glamour"], "r+") do |io|
            io.write("#{width}\n")
            io.write(text)
            io.close_write
            io.read
          end
        end

        def render_chat_tool_detail_block(block)
          body = block.content.to_s.strip
          body = "(empty)" if body.empty?
          wrapped_body = wrap_text(body, [bubble_content_width, 10].max)
          tool_call_body_style.render(wrapped_body.lines.map(&:chomp).join("\n"))
        end

        def chat_message_group_item(agent, blocks)
          first = blocks.first
          role = first.role.to_s
          inquiry_response = inquiry_response_message?(first)

          {
            kind: :message,
            label: chat_message_group_label(agent, role, inquiry_response:),
            detail_title: chat_message_group_detail_title(agent, role, inquiry_response:),
            summary: chat_block_summary(blocks.map(&:content).join("\n")),
            preview: blocks.map { |block| chat_message_preview_content(block) }.join("\n\n"),
            inquiry_response:,
            content_builder: -> { blocks.map { |block| render_chat_message_detail_block(block) }.join("\n\n") }
          }
        end

        def chat_message_group_signature(block)
          [block.role.to_s, inquiry_response_message?(block)]
        end

        def inquiry_response_message?(block)
          return true if block.is_a?(Hash) && block[:inquiry_response]

          metadata = block.respond_to?(:metadata) ? block.metadata : block[:metadata]
          metadata.is_a?(Hash) && metadata["inquiry_response"] == true
        end

        def chat_message_preview_content(block)
          return block.content.to_s unless block.role.to_s == "user"

          format_json_object_message(block.content.to_s) || block.content.to_s
        end

        def chat_message_group_label(agent, role, inquiry_response: false)
          return "#{Styles::STATUS_ICONS[:awaiting_input]} User Answers" if inquiry_response

          case role
          when "user" then "You"
          when "assistant" then agent_display_name(agent)
          else role.upcase
          end
        end

        def chat_message_group_detail_title(agent, role, inquiry_response: false)
          return "User Answers" if inquiry_response

          case role
          when "user" then "User Message"
          when "assistant" then "#{agent_display_name(agent)} Message"
          else "#{role.upcase} Message"
          end
        end

        def agent_display_name(agent)
          agent.respond_to?(:display_name) ? agent.display_name.to_s : agent.name.to_s
        end

        def chat_tool_group_item(blocks)
          summary = chat_tool_group_summary(blocks)
          rendered = if blocks.length > 1
                       blocks.map { |block| render_chat_tool_detail_block(block) }.join("\n\n")
                     else
                       render_chat_tool_detail_block(blocks.first)
                     end

          {
            kind: :tool_group,
            label: blocks.length > 1 ? "Tool Call Group" : tool_block_label(blocks.first),
            detail_title: blocks.length > 1 ? "Tool Calls" : tool_block_label(blocks.first),
            summary: summary,
            content: rendered
          }
        end

        def render_chat_block_detail
          block = @agent_chat_form.selected_block
          return @agent_chat_form.block_viewport.view unless block

          width = [chat_content_width - 4, 20].max
          render_chat_detail_layer(@agent_chat_form.block_viewport.view, width,
                                   border_color: chat_block_detail_border_color(block))
        end

        def render_chat_summary_detail
          width = [chat_content_width - 4, 20].max
          render_chat_detail_layer(@agent_chat_form.summary_detail_viewport.view, width)
        end

        def render_chat_detail_layer(content, width, border_color: Styles::COLORS[:notice])
          rendered = chat_block_detail_style(width, border_color: border_color).render(content)
          rendered.lines.map { |line| "#{horizontal_margin_prefix} #{line.chomp}" }.join("\n")
        end

        def chat_block_detail_border_color(block)
          case block[:kind]
          when :message
            return Styles::COLORS[:warning] if block[:inquiry_response]

            block[:label].to_s == "You" ? Styles::COLORS[:accent] : Styles::COLORS[:highlight]
          when :tool_group
            Styles::COLORS[:notice]
          else
            Styles::COLORS[:notice]
          end
        end

        def agent_chat_summary_detail_text(agent)
          wrap_text(fade_token_usage(agent.last_summary.to_s), [bubble_content_width - 4, 10].max)
        end

        def render_chat_conversation_block_list(blocks)
          return system_note(chat_message_style.render("No conversation yet")) if blocks.empty?

          offset = 0
          rows = blocks.each_with_index.map do |block, index|
            selected = @agent_chat_form&.selected_block_index == index
            row = render_chat_conversation_block_row(block, selected:)
            block[:line_offset] = offset
            block[:line_height] = row.lines.count
            offset += block[:line_height] + 1
            row
          end
          content = rows.join("\n\n")
          padding = [@agent_chat_form&.viewport&.height.to_i, 0].max
          padding.positive? ? "#{content}\n#{Array.new(padding, "").join("\n")}" : content
        end

        def render_chat_conversation_block_row(block, selected:)
          width = [bubble_content_width, 10].max
          padded_width = [width - 2, 10].max
          label_line = Bubbles::ANSI.cut_string(styled_chat_block_label(block, selected:), 0, padded_width)
          body = render_chat_block_preview(block, width)
          rendered = [chat_message_style.render(label_line), body].join("\n")
          system_note(rendered)
        end

        def render_chat_block_preview(block, width)
          if block[:kind] == :message
            text_width = [width - 2, 10].max
            text = hard_wrap_chat_preview(wrap_text(block[:preview].to_s, text_width), text_width)
            style = chat_message_preview_style(block)
            style.render(indent_chat_block_preview(text))
          else
            body_line = Bubbles::ANSI.cut_string("  #{block[:summary]}", 0, [width - 2, 10].max)
            chat_message_style.render(body_line)
          end
        end

        def hard_wrap_chat_preview(text, width)
          text.to_s.lines(chomp: true).flat_map do |line|
            hard_wrap_chat_preview_line(line, width)
          end.join("\n")
        end

        def hard_wrap_chat_preview_line(line, width)
          return [""] if line.empty?

          line.each_char.each_slice(width).map(&:join)
        end

        def indent_chat_block_preview(text)
          text.to_s.lines.map { |line| "  #{line.chomp}" }.join("\n")
        end

        def styled_chat_block_label(block, selected:)
          text = selected ? "#{Styles::MARKERS[:cursor]} #{block[:label]}" : block[:label].to_s
          return selected_tab_style.render(" #{text} ") if selected

          chat_block_label_style(block).render(text)
        end

        def chat_block_label_style(block)
          return tool_group_label_style if block[:kind] == :tool_group
          return inquiry_progress_style if block[:kind] == :message && block[:inquiry_response]
          return user_name_tag_style if block[:kind] == :message && block[:label].to_s == "You"
          return assistant_name_tag_style if block[:kind] == :message

          selected_style
        end

        def chat_message_preview_style(block)
          return inquiry_message_style if block[:inquiry_response]

          block[:label].to_s == "You" ? user_message_style : assistant_message_style
        end

        def chat_tool_group_summary(blocks)
          call_count = blocks.count { |block| block.kind == :tool_call }
          result_count = blocks.count { |block| block.kind == :tool_result }
          parts = []
          parts << "#{call_count} tool call#{"s" if call_count != 1}" if call_count.positive?
          parts << "#{result_count} result#{"s" if result_count != 1}" if result_count.positive?

          names = blocks.filter_map do |block|
            next if block.kind == :tool_result

            value = block.tool_name.to_s.strip
            generic_tool_name?(value) ? nil : value
          end.uniq

          summary = parts.join(", ")
          summary = "#{summary}: #{names.join(", ")}" unless names.empty?
          summary
        end

        def generic_tool_name?(value)
          value.empty? || value == "tool"
        end

        def tool_block_label(block)
          return "Tool result" if block.kind == :tool_result

          name = block.tool_name.to_s.strip
          generic_tool_name?(name) ? "Tool call" : name
        end

        def chat_block_summary(content)
          first_line = content.to_s.lines.map(&:strip).find { |line| !line.empty? }.to_s
          Bubbles::ANSI.cut_string(first_line, 0, 120)
        end

        def system_note(content)
          system_message_style.render(content)
        end

        def align_chat_bubble(rendered)
          rendered.lines.map(&:chomp).join("\n")
        end

        def chat_meta_lines(agent)
          prefix = horizontal_margin_prefix
          execution_parts = ["template=#{agent.template_key}", "agent=#{agent.agent}"]
          execution_parts << "model=#{agent.model}" unless agent.model.to_s.empty?
          execution_parts << "effort=#{agent.reasoning_effort}" unless agent.reasoning_effort.to_s.empty?
          execution_parts << "sandbox=#{agent.sandbox_mode}"
          execution_parts << "workspace=#{compact_workspace_path(agent.workspace)}"
          lines = [
            execution_parts.join("  "),
            "created #{format_time(agent.created_at)}  #{Styles::MARKERS[:bullet_sep]}  runs #{agent.run_count}  #{Styles::MARKERS[:bullet_sep]}  last result #{agent.last_result_label}"
          ]
          lines.map { |line| dim_style.render("#{prefix}#{wrap_text(line, chat_content_width)}") }.join("\n")
        end

        CHAT_DIVIDER_SENTINEL = "​"
        CHAT_DIVIDER_FLUSH_SENTINEL = "‌"
        CHAT_DIVIDER_RIGHT_FLUSH_SENTINEL = "‍"

        def chat_section_divider(label: nil, focused: false, right: nil, right_prestyled: false)
          total_width = [chat_divider_width, 12].max

          if label.nil? || label.to_s.empty?
            return "#{CHAT_DIVIDER_FLUSH_SENTINEL}#{chat_border_style.render(Styles::BOX[:h] * total_width)}"
          end

          label_text = focused ? "#{Styles::MARKERS[:cursor]} #{label}" : label.to_s
          label_rendered = focused ? chat_section_label_focused_style.render(label_text) : chat_section_label_style.render(label_text)
          label_width = visible_width(label_rendered)
          right_text = right.to_s
          if right_text.empty?
            marker = CHAT_DIVIDER_RIGHT_FLUSH_SENTINEL
            consumed = label_width + 1
            remaining = [total_width - consumed, 0].max
            line = chat_border_style.render(Styles::BOX[:h] * remaining)
            return "#{marker}#{label_rendered} #{line}"
          end

          marker = CHAT_DIVIDER_SENTINEL
          max_right_width = [total_width - label_width - 3, 0].max
          cut_right = Bubbles::ANSI.cut_string(right_text, 0, max_right_width)
          right_rendered = right_prestyled ? cut_right : chat_border_style.render(cut_right)
          right_width = visible_width(right_rendered)
          consumed = label_width + 1 + 1 + right_width
          remaining = [total_width - consumed, 0].max
          line = chat_border_style.render(Styles::BOX[:h] * remaining)
          "#{marker}#{label_rendered} #{line} #{right_rendered}"
        end

        def render_skill_picker(picker)
          prefix = horizontal_margin_prefix
          inner_width = [chat_content_width - 2, 10].max

          rows = picker.visible_window
          if rows.empty?
            label = "No skills match"
            padded = if label.length >= inner_width
                       label[0,
                             inner_width]
                     else
                       "#{label}#{" " * (inner_width - label.length)}"
                     end
            return "#{prefix}#{dim_style.render(" #{padded} ")}"
          end

          highlight_row = picker.highlight_index - picker.scroll_offset
          lines = rows.each_with_index.map do |skill, index|
            label = "#{picker.trigger}#{skill["name"]}"
            padded = if label.length >= inner_width
                       label[0,
                             inner_width]
                     else
                       "#{label}#{" " * (inner_width - label.length)}"
                     end
            styled = index == highlight_row ? selected_style.render(" #{padded} ") : chat_input_style.render(" #{padded} ")
            "#{prefix}#{styled}"
          end
          lines.join("\n")
        end

        def render_chat_input_block(composer)
          composer.input_view.lines.map do |line|
            rendered = Bubbles::ANSI.cut_string(line.chomp, 0, chat_content_width)
            padding = [chat_content_width - Bubbles::ANSI.strip(rendered).length, 0].max
            rendered = "#{rendered}#{" " * padding}"
            "#{horizontal_margin_prefix}#{composer.content.empty? ? chat_placeholder_style.render(rendered) : chat_input_style.render(rendered)}"
          end.join("\n")
        end

        def render_chat_inquiry_form(form)
          return render_chat_inquiry_review(form) if form.review?

          field = form.current_field
          inner_width = [chat_content_width - 4, 10].max

          body_lines = []
          body_lines << inquiry_progress_style.render("Question #{form.field_index + 1}/#{form.fields.length}:")

          requirement_label = field.required ? "required" : "optional"
          requirement_style = field.required ? inquiry_required_style : inquiry_optional_style
          suffix_budget = requirement_label.length + 1
          wrapped_label = wrap_text(field.label, [inner_width - suffix_budget, 10].max).lines.map(&:chomp)
          wrapped_label[0..-2].each { |line| body_lines << inquiry_question_style.render(line) }
          last_line = wrapped_label.last.to_s
          body_lines << "#{inquiry_question_style.render(last_line)} #{requirement_style.render(requirement_label)}"

          unless field.description.to_s.strip.empty?
            wrap_text(field.description, inner_width).lines.each do |line|
              body_lines << dim_style.render(line.chomp)
            end
          end

          body_lines << ""
          form.current_input_view.lines.each do |line|
            rendered = Bubbles::ANSI.cut_string(line.chomp, 0, inner_width)
            padding = [inner_width - Bubbles::ANSI.strip(rendered).length, 0].max
            rendered = "#{rendered}#{" " * padding}"
            style = form.picker? || form.value_present?(field) ? chat_input_style : chat_placeholder_style
            body_lines << style.render(rendered)
          end

          if form.error_message
            body_lines << ""
            wrap_text(form.error_message, inner_width).lines.each do |line|
              body_lines << fail_style.render(line.chomp)
            end
          end

          render_inquiry_box(body_lines.join("\n"))
        end

        def render_chat_inquiry_review(form)
          inner_width = [chat_content_width - 4, 10].max

          body_lines = []
          body_lines << inquiry_progress_style.render("Question #{form.field_index + 1}/#{form.fields.length}:")
          body_lines << "#{inquiry_question_style.render("Review & submit")} #{inquiry_optional_style.render("confirm")}"
          wrap_text("Confirm your answers before sending them to the agent.", inner_width).lines.each do |line|
            body_lines << dim_style.render(line.chomp)
          end

          body_lines << ""
          form.review_rows.each do |label, value|
            wrap_text("#{label}: #{value}", inner_width).lines.each do |line|
              body_lines << chat_input_style.render(line.chomp)
            end
          end

          missing = form.missing_required_labels
          if missing.any?
            body_lines << ""
            wrap_text("Answers required: #{missing.join(", ")}", inner_width).lines.each do |line|
              body_lines << fail_style.render(line.chomp)
            end
          end

          body_lines << ""
          form.current_field.input.view.lines.each do |line|
            rendered = Bubbles::ANSI.cut_string(line.chomp, 0, inner_width)
            padding = [inner_width - Bubbles::ANSI.strip(rendered).length, 0].max
            rendered = "#{rendered}#{" " * padding}"
            body_lines << chat_input_style.render(rendered)
          end

          if form.error_message
            body_lines << ""
            wrap_text(form.error_message, inner_width).lines.each do |line|
              body_lines << fail_style.render(line.chomp)
            end
          end

          render_inquiry_box(body_lines.join("\n"))
        end

        def render_inquiry_box(body)
          indent_suffix = 2
          rendered = inquiry_box_style(chat_content_width - indent_suffix).render(body)
          prefix = horizontal_margin_prefix
          rendered.lines.map { |line| "#{prefix}#{line.chomp}" }.join("\n")
        end

        def format_chat_message_content(content, role)
          return wrap_text(content, bubble_content_width) unless role == "user"

          formatted = format_json_object_message(content)
          formatted || wrap_text(content, bubble_content_width)
        end

        def format_json_object_message(content)
          parsed = JSON.parse(content.to_s)
          return nil unless parsed.is_a?(Hash) && !parsed.empty?

          parsed.map do |key, value|
            "#{json_object_key_style.render(humanize_json_key(key))}\n" \
              "#{json_object_value_style.render(json_object_value_text(value))}"
          end.join("\n")
        rescue JSON::ParserError
          nil
        end

        def json_object_value_text(value)
          rendered = value.is_a?(String) ? value : JSON.pretty_generate(value)
          wrap_text(rendered, [bubble_content_width, 10].max)
        end

        def humanize_json_key(key)
          words = key.to_s.strip.split(/[_\s-]+/).reject(&:empty?).join(" ")
          return key.to_s if words.empty?

          words.upcase
        end

        def json_object_key_style
          @json_object_key_style ||= Lipgloss::Style.new.bold(true)
        end

        def json_object_value_style
          @json_object_value_style ||= Lipgloss::Style.new.italic(true)
        end

        def fancy_list(items)
          Lipgloss::List.new
            .enumerator(:bullet)
            .enumerator_style(fancy_list_marker_style)
            .item_style(fancy_list_item_style)
            .items(items)
            .render
        end

        def fancy_list_item(label, value)
          wrapped = wrap_text(value.to_s, [bubble_content_width - 4, 10].max)
          [
            fancy_list_title_style.render(label),
            fancy_list_body_style.render(wrapped)
          ].join("\n")
        end
      end
    end
  end
end
