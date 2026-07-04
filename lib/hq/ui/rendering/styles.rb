# frozen_string_literal: true

require "lipgloss"

module HQ
  module UI
    module Rendering
      module Styles
        ICONS = {
          agent: "\u{f06a9}",
          project: "\u{f07b}",
          group: "\u{f0849}",
          pr: "\u{ea64}",
          github: "\u{ea84}",
          branch: "\u{e725}",
          commit: "\u{eafc}",
          run: "\u{f046e}",
          result: "\u{f15ab}",
          summary: "\u{f036}",
          prompt: "\u{f0477}",
          workspace: "\u{f0770}",
          session: "\u{f0306}",
          log: "\u{f4ed}",
          sandbox: "\u{f0494}",
          template: "\u{f02d6}",
          clock: "\u{f0150}"
        }.freeze

        STATUS_ICONS = {
          healthy: "\u{f058}",
          maintenance: "\u{f071}",
          warning: "\u{f06a}",
          fail: "\u{f057}",
          pending: "\u{f111}",
          dim: "\u{f111}",
          running: "\u{f0150}",
          succeeded: "\u{f058}",
          failed: "\u{f057}",
          stopped: "\u{f04d}",
          awaiting_input: "\u{f059}",
          partial: "\u{f0c8}",
          blocked: "\u{f05e}",
          unknown: "\u{f111}"
        }.freeze

        MARKERS = {
          cursor: "\u{f06c2}",
          more_up: "▴",
          more_down: "▾",
          unread: "\u{f116b}",
          bullet_sep: "•",
          check: "✓",
          cross: "✗",
          bang: "!",
          dot: "●",
          triangle: "▲",
          circle: "○",
          block_count: "≡",
          visible_count: "◧"
        }.freeze

        KEYS = {
          tab: "⇥",
          ctrl: "⌃",
          shift: "\u{f0636}",
          arrow_left: "←",
          arrow_right: "→",
          arrow_up: "↑",
          arrow_down: "↓"
        }.freeze

        BOX = {
          h: "─",
          v: "│",
          t_left: "├",
          t_right: "┤"
        }.freeze

        COLORS = {
          accent: "#FF79C6",
          accent_alt: "#BD93F9",
          text: "#F8F8F2",
          text_muted: "#6272A4",
          text_subtle: "#D7E3FC",
          text_inverse: "#0A0A0A",
          surface_selected: "#44475A",
          success: "#50FA7B",
          danger: "#FF5555",
          warning: "#FFB86C",
          notice: "#8BE9FD",
          notice_alt: "#9AD1D4",
          highlight: "#F1FA8C",
          accent_muted: "#804065",
          highlight_muted: "#7A8046",
          accent_alt_muted: "#5E497C",
          notice_muted: "#315A66"
        }.freeze

        private

        def title_style
          @title_style ||= Lipgloss::Style.new.bold(true).foreground(COLORS[:accent]).padding(0, 1)
        end

        def tab_style
          @tab_style ||= Lipgloss::Style.new.foreground(COLORS[:text_muted])
        end

        def selected_tab_style
          @selected_tab_style ||= Lipgloss::Style.new.bold(true).foreground(COLORS[:text]).background(COLORS[:surface_selected])
        end

        def selected_style
          @selected_style ||= Lipgloss::Style.new.bold(true).foreground(COLORS[:text]).background(COLORS[:surface_selected])
        end

        def button_style
          @button_style ||= Lipgloss::Style.new.bold(true).foreground(COLORS[:text_inverse]).background(COLORS[:highlight])
        end

        def selected_button_style
          @selected_button_style ||= Lipgloss::Style.new.bold(true).foreground(COLORS[:text]).background(COLORS[:accent])
        end

        def healthy_style
          @healthy_style ||= Lipgloss::Style.new.bold(true).foreground(COLORS[:success])
        end

        def fail_style
          @fail_style ||= Lipgloss::Style.new.bold(true).foreground(COLORS[:danger])
        end

        def maintenance_style
          @maintenance_style ||= Lipgloss::Style.new.bold(true).foreground(COLORS[:warning])
        end

        def pending_style
          @pending_style ||= Lipgloss::Style.new.foreground(COLORS[:text_muted])
        end

        def dim_style
          @dim_style ||= Lipgloss::Style.new.foreground(COLORS[:text_muted])
        end

        def chat_section_label_style
          background = chat_screen_border_color
          Lipgloss::Style.new.bold(true)
                          .foreground(best_contrast_text_color(background))
                          .background(background)
                          .padding(0, 1)
        end

        def chat_section_label_focused_style
          @chat_section_label_focused_style ||= begin
            background = COLORS[:accent]
            Lipgloss::Style.new.bold(true)
                            .foreground(best_contrast_text_color(background))
                            .background(background)
                            .padding(0, 1)
          end
        end

        def summary_style
          @summary_style ||= Lipgloss::Style.new.italic(true).foreground(COLORS[:text_muted])
        end

        def confirm_style
          @confirm_style ||= Lipgloss::Style.new.bold(true).foreground(COLORS[:highlight])
        end

        def footer_style
          @footer_style ||= Lipgloss::Style.new.foreground(COLORS[:text_muted]).padding(0)
        end

        def footer_confirm_style
          @footer_confirm_style ||= Lipgloss::Style.new.bold(true).foreground(COLORS[:highlight]).padding(0, 1)
        end

        def success_style
          @success_style ||= Lipgloss::Style.new.bold(true).foreground(COLORS[:success])
        end

        def warning_style
          @warning_style ||= Lipgloss::Style.new.foreground(COLORS[:warning])
        end

        def detail_style
          color = @screen == :agents ? agent_detail_border_color : COLORS[:accent_alt]
          Lipgloss::Style.new.border(:rounded).border_foreground(color).padding(0, 1).width(panel_total_width)
        end

        def agent_detail_border_color
          agent = respond_to?(:selected_agent, true) ? selected_agent : nil
          index = agent&.color_index
          return COLORS[:accent_alt] unless index

          CHAT_BORDER_PALETTE[index % CHAT_BORDER_PALETTE.length]
        end

        def sidebar_style
          Lipgloss::Style.new.border(:rounded).border_foreground(COLORS[:notice]).padding(0, 1).width(panel_total_width)
        end

        # 30 distinct golden-angle HSL colors for per-agent chat border tinting.
        CHAT_BORDER_PALETTE = [
          "#DD5F5F", "#5FDD84", "#A95FDD", "#DDCD5F", "#5FC8DD",
          "#DD5FA3", "#7FDD5F", "#645FDD", "#DD895F", "#5FDDAE",
          "#D35FDD", "#C3DD5F", "#5F9EDD", "#DD5F79", "#5FDD6A",
          "#8F5FDD", "#DDB35F", "#5FDDD8", "#DD5FBD", "#99DD5F",
          "#5F74DD", "#DD6F5F", "#5FDD94", "#B95FDD", "#DDDD5F",
          "#5FB8DD", "#DD5F93", "#6EDD5F", "#755FDD", "#DD995F"
        ].freeze

        def chat_screen_border_color
          index = @agent_chat_form&.agent&.color_index
          return COLORS[:notice] unless index

          CHAT_BORDER_PALETTE[index % CHAT_BORDER_PALETTE.length]
        end

        def chat_sidebar_style
          Lipgloss::Style.new.border(:rounded).border_foreground(chat_screen_border_color).padding(0, 1).width(panel_total_width)
        end

        def chat_border_style
          Lipgloss::Style.new.foreground(chat_screen_border_color)
        end

        def best_contrast_text_color(background)
          [COLORS[:text], COLORS[:text_inverse]].max_by do |foreground|
            contrast_ratio(foreground, background)
          end
        end

        def contrast_ratio(first_color, second_color)
          first = relative_luminance(first_color)
          second = relative_luminance(second_color)
          lighter, darker = [first, second].max, [first, second].min
          (lighter + 0.05) / (darker + 0.05)
        end

        def relative_luminance(color)
          red, green, blue = hex_rgb(color).map do |channel|
            value = channel / 255.0
            value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055)**2.4
          end
          (0.2126 * red) + (0.7152 * green) + (0.0722 * blue)
        end

        def hex_rgb(color)
          hex = color.to_s.delete_prefix("#")
          return [0, 0, 0] unless hex.match?(/\A[0-9a-fA-F]{6}\z/)

          hex.scan(/../).map { |component| component.to_i(16) }
        end

        def list_card_style
          Lipgloss::Style.new.border(:rounded).border_foreground(COLORS[:accent_alt]).padding(0,
                                                                                              1).width(list_sidebar_total_width)
        end

        def detail_overlay_style
          Lipgloss::Style.new.border(:rounded).border_foreground(COLORS[:accent]).padding(1,
                                                                                          2).width([@window_width - 4,
                                                                                                    20].max)
        end

        def log_header_style
          @log_header_style ||= Lipgloss::Style.new.bold(true).foreground(COLORS[:notice])
        end

        def assistant_message_style
          @assistant_message_style ||= Lipgloss::Style.new.foreground(COLORS[:highlight])
        end

        def user_message_style
          @user_message_style ||= Lipgloss::Style.new.foreground(COLORS[:accent])
        end

        def pending_user_message_style
          @pending_user_message_style ||= Lipgloss::Style.new.foreground(COLORS[:accent_alt])
        end

        def user_name_tag_style
          @user_name_tag_style ||= Lipgloss::Style.new.bold(true).foreground(COLORS[:text]).background(COLORS[:accent_muted]).padding(
            0, 1
          )
        end

        def assistant_name_tag_style
          @assistant_name_tag_style ||= Lipgloss::Style.new.bold(true).foreground(COLORS[:text]).background(COLORS[:highlight_muted]).padding(
            0, 1
          )
        end

        def pending_user_name_tag_style
          @pending_user_name_tag_style ||= Lipgloss::Style.new.bold(true).foreground(COLORS[:text]).background(COLORS[:accent_alt_muted]).padding(
            0, 1
          )
        end

        def inquiry_message_style
          @inquiry_message_style ||= Lipgloss::Style.new.foreground(COLORS[:notice_alt])
        end

        def inquiry_box_style(width)
          Lipgloss::Style.new.border(:rounded).border_foreground(COLORS[:notice]).padding(0, 1).width(width)
        end

        def chat_block_detail_style(width, border_color: COLORS[:notice])
          Lipgloss::Style.new.border(:rounded).border_foreground(border_color).padding(0, 1).width(width)
        end

        def delete_dialog_style(width)
          Lipgloss::Style.new.border(:rounded).border_foreground(COLORS[:danger]).padding(1, 2).width(width)
        end

        def loading_dialog_style(width)
          Lipgloss::Style.new.border(:rounded).border_foreground(COLORS[:accent]).padding(1, 2).width(width)
        end

        def omnisearch_dialog_style(width)
          Lipgloss::Style.new.border(:rounded).border_foreground(COLORS[:accent]).padding(0, 1).width(width)
        end

        def omnisearch_input_style
          @omnisearch_input_style ||= Lipgloss::Style.new.bold(true).foreground(COLORS[:text])
        end

        def delete_dialog_title_style
          @delete_dialog_title_style ||= Lipgloss::Style.new.bold(true).foreground(COLORS[:danger])
        end

        def delete_dialog_excerpt_style
          @delete_dialog_excerpt_style ||= Lipgloss::Style.new.foreground(COLORS[:text_muted])
        end

        def delete_dialog_button_style
          @delete_dialog_button_style ||= Lipgloss::Style.new.padding(0, 3).foreground(COLORS[:text_muted])
        end

        def delete_dialog_button_selected_style
          @delete_dialog_button_selected_style ||= Lipgloss::Style.new.bold(true).padding(0,
                                                                                          3).foreground(COLORS[:text]).background(COLORS[:danger])
        end

        def inquiry_required_style
          @inquiry_required_style ||= Lipgloss::Style.new.bold(true).foreground(COLORS[:warning])
        end

        def inquiry_optional_style
          @inquiry_optional_style ||= Lipgloss::Style.new.foreground(COLORS[:text_muted])
        end

        def inquiry_question_style
          @inquiry_question_style ||= Lipgloss::Style.new.bold(true).foreground(COLORS[:text])
        end

        def inquiry_progress_style
          @inquiry_progress_style ||= Lipgloss::Style.new.foreground(COLORS[:notice])
        end

        def fancy_list_marker_style
          @fancy_list_marker_style ||= Lipgloss::Style.new.foreground(COLORS[:accent])
        end

        def fancy_list_title_style
          @fancy_list_title_style ||= Lipgloss::Style.new.bold(true).foreground(COLORS[:accent])
        end

        def fancy_list_body_style
          @fancy_list_body_style ||= Lipgloss::Style.new.foreground(COLORS[:accent_alt])
        end

        def fancy_list_item_style
          @fancy_list_item_style ||= Lipgloss::Style.new
        end

        def system_message_style
          @system_message_style ||= Lipgloss::Style.new.foreground(COLORS[:text_muted])
        end

        def tool_call_label_style
          @tool_call_label_style ||= Lipgloss::Style.new.bold(true).foreground(COLORS[:notice]).background(COLORS[:surface_selected]).padding(
            0, 1
          )
        end

        def tool_group_label_style
          @tool_group_label_style ||= Lipgloss::Style.new.bold(true).foreground(COLORS[:notice]).background(COLORS[:notice_muted]).padding(
            0, 1
          )
        end

        def tool_call_body_style
          @tool_call_body_style ||= Lipgloss::Style.new.foreground(COLORS[:text_muted])
        end

        def tool_result_label_style
          @tool_result_label_style ||= Lipgloss::Style.new.bold(true).foreground(COLORS[:warning])
        end

        def live_log_style
          @live_log_style ||= Lipgloss::Style.new.foreground(COLORS[:text_subtle])
        end

        def chat_message_style
          @chat_message_style ||= Lipgloss::Style.new.padding(0, 1)
        end

        def chat_input_style
          @chat_input_style ||= Lipgloss::Style.new.foreground(COLORS[:text])
        end

        def chat_placeholder_style
          @chat_placeholder_style ||= Lipgloss::Style.new.foreground(COLORS[:text_muted])
        end
      end
    end
  end
end
