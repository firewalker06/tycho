# frozen_string_literal: true

module HQ
  module UI
    module Rendering
      module Views
        TYCHO_LOGOTYPE_LINES = [
          "\e[38;5;199m████████╗██╗   ██╗ ██████╗██╗  ██╗ ██████╗\e[0m",
          "\e[38;5;205m╚══██╔══╝╚██╗ ██╔╝██╔════╝██║  ██║██╔═══██╗\e[0m",
          "\e[38;5;213m   ██║    ╚████╔╝ ██║     ███████║██║   ██║\e[0m",
          "\e[38;5;221m   ██║     ╚██╔╝  ██║     ██╔══██║██║   ██║\e[0m",
          "\e[38;5;215m   ██║      ██║   ╚██████╗██║  ██║╚██████╔╝\e[0m",
          "\e[38;5;231m   ╚═╝      ╚═╝    ╚═════╝╚═╝  ╚═╝ ╚═════╝\e[0m"
        ].freeze

        private

        def loading_screen_view
          dialog_width = [[@window_width - 10, 72].min, 47].max
          inner_width = [dialog_width - 4, 20].max

          done, total = progress_counts
          count_line = total.positive? ? "#{done} / #{total} steps" : "Preparing..."

          @progress.width = inner_width
          bar = @progress.view

          activity = progress_activity_snapshot.last(6)
          current = activity.last
          history = activity[0...-1]

          current_line = if current
                           accent_style = fancy_list_title_style
                           accent_style.render(truncate(current, inner_width))
                         else
                           dim_style.render("Waiting...")
                         end
          history_lines = history.map { |line| dim_style.render(truncate(line, inner_width)) }

          body_parts = [
            loading_logotype,
            "",
            fancy_list_title_style.render("Tycho is starting up"),
            "",
            bar,
            dim_style.render(count_line),
            "",
            current_line
          ]
          unless history_lines.empty?
            body_parts << ""
            body_parts.concat(history_lines)
          end

          body = Lipgloss.join_vertical(:left, *body_parts)
          dialog = loading_dialog_style(dialog_width).render(body)
          Lipgloss.place(@window_width, @window_height, :center, :center, dialog)
        end

        def loading_logotype
          TYCHO_LOGOTYPE_LINES.map { |line| pad_visible(line, 43) }.join("\n")
        end

        def config_error_view
          [
            title_style.render("Tycho - Ops Cockpit"),
            "",
            fail_style.render("  Configuration error"),
            "  #{@config_error}",
            "",
            dim_style.render("  Expected config: #{@registry&.path || Registry::DEFAULT_PATH}"),
            dim_style.render("  q: quit")
          ].join("\n")
        end

        def agent_editor_body
          project_label = icon_label(:project, @agent_editor.project)
          template_lines = selector_field_lines(
            label: "Template",
            current: @agent_editor.template_label,
            choices: @agent_editor.template_choices.map(&:name),
            selected_index: @agent_editor.template_index,
            focused: @agent_editor.template_focused?,
            width: [sidebar_content_width - 2, 20].max
          )
          harness_lines = selector_field_lines(
            label: "Harness",
            current: @agent_editor.harness,
            choices: @agent_editor.harness_options,
            selected_index: @agent_editor.harness_index,
            focused: @agent_editor.harness_focused?,
            width: [sidebar_content_width - 2, 20].max
          )
          name_line = @agent_editor.field_index == @agent_editor.name_field_index ? selected_style.render("  #{@agent_editor.name_input.view}") : "  #{@agent_editor.name_input.view}"
          workspace_field_index = @agent_editor.workspace_field_index
          prompt_field_index = @agent_editor.prompt_field_index
          prompt_label = @agent_editor.field_index == prompt_field_index ? selected_style.render("  Prompt:") : "  Prompt:"
          prompt_body = @agent_editor.prompt_input.view.lines.map do |line|
            rendered = "  #{line.chomp}"
            @agent_editor.field_index == prompt_field_index ? selected_style.render(rendered) : rendered
          end.join("\n")
          submit_line = render_agent_editor_buttons
          body_lines = [
            "#{@agent_editor.title} for #{project_label}",
            ""
          ]
          body_lines.concat(template_lines)
          body_lines << ""
          body_lines.concat(harness_lines)
          body_lines << ""
          body_lines << name_line
          if workspace_field_index
            workspace_line = @agent_editor.field_index == workspace_field_index ? selected_style.render("  #{@agent_editor.workspace_input.view}") : "  #{@agent_editor.workspace_input.view}"
            body_lines << workspace_line
          end
          body_lines.concat([
                              prompt_label,
                              prompt_body,
                              ""
                            ])
          if @agent_editor.error_message
            body_lines << fail_style.render("  #{@agent_editor.error_message}")
            body_lines << ""
          end
          body_lines.concat([
                              submit_line,
                              "",
                              dim_style.render("  #{Styles::KEYS[:arrow_left]}/#{Styles::KEYS[:arrow_right]}: change selected option  #{Styles::MARKERS[:bullet_sep]}  #{Styles::KEYS[:tab]}: next field  #{Styles::MARKERS[:bullet_sep]}  enter: newline or submit  #{Styles::MARKERS[:bullet_sep]}  esc: cancel")
                            ])
          body_lines.join("\n")
        end

        def render_agent_editor_buttons
          if @agent_editor.mode == :edit
            label = @agent_editor.submit_label
            style = @agent_editor.submit_focused? ? selected_button_style : button_style
            return "  #{style.render("  #{label}  ")}"
          end

          create_label = "Create Agent"
          run_label = "Create and Run Agent"
          create_style = @agent_editor.create_button_focused? ? selected_button_style : button_style
          run_style = @agent_editor.create_and_run_button_focused? ? selected_button_style : button_style
          spacer = Lipgloss::Style.new.width(2).render("")
          buttons = Lipgloss.join_horizontal(
            :top,
            create_style.render("  #{create_label}  "),
            spacer,
            run_style.render("  #{run_label}  ")
          )
          "  #{buttons}"
        end

        def project_editor_body
          field_width = [sidebar_content_width - 2, 20].max

          path_line = render_project_editor_field(@project_editor.path_input, @project_editor.path_field_index)
          key_line = render_project_editor_field(@project_editor.key_input, @project_editor.key_field_index)
          name_line = render_project_editor_field(@project_editor.name_input, @project_editor.name_field_index)
          group_line = render_project_editor_field(@project_editor.group_input, @project_editor.group_field_index)

          agent_lines = selector_field_lines(
            label: "Agent",
            current: @project_editor.agent,
            choices: @project_editor.agent_options,
            selected_index: @project_editor.agent_index,
            focused: @project_editor.agent_focused?,
            width: field_width
          )

          detected = @project_editor.kamal_app_detected?
          apps_info_line = dim_style.render(
            "  Kamal app: #{detected ? "detected (config/deploy.yml found)" : "not detected"}"
          )

          submit_label = "Create Project"
          submit_style = @project_editor.submit_focused? ? selected_button_style : button_style
          submit_line = "  #{submit_style.render("  #{submit_label}  ")}"

          path_suggestions = @project_editor.path_focused? ? render_editor_suggestions : []
          group_suggestions = @project_editor.group_focused? ? render_editor_suggestions : []

          body_lines = [
            @project_editor.title,
            "",
            path_line
          ]
          body_lines.concat(path_suggestions)
          body_lines << ""
          body_lines << key_line
          body_lines << name_line
          body_lines << group_line
          body_lines.concat(group_suggestions)
          body_lines << ""
          body_lines.concat(agent_lines)
          body_lines << ""
          body_lines << apps_info_line
          body_lines << ""
          if @project_editor.error_message
            body_lines << fail_style.render("  #{@project_editor.error_message}")
            body_lines << ""
          end
          body_lines << submit_line
          body_lines << ""
          body_lines << dim_style.render("  #{Styles::KEYS[:arrow_left]}/#{Styles::KEYS[:arrow_right]}: change option  #{Styles::MARKERS[:bullet_sep]}  #{Styles::KEYS[:tab]}: next field  #{Styles::MARKERS[:bullet_sep]}  enter: select/submit  #{Styles::MARKERS[:bullet_sep]}  esc: cancel")
          body_lines.join("\n")
        end

        def render_editor_suggestions
          return [] unless @project_editor.suggestions_visible?

          lines = []
          total = @project_editor.suggestions.length
          visible = @project_editor.visible_suggestions
          offset = @project_editor.instance_variable_get(:@suggestion_offset)
          shorten_home = @project_editor.path_focused?

          lines << dim_style.render("    #{Styles::MARKERS[:more_up]} more") if offset > 0

          home = Dir.home
          visible.each_with_index do |value, index|
            display = shorten_home && value.start_with?("#{home}/") ? value.sub(home, "~") : value
            if @project_editor.visible_suggestion_selected?(index)
              lines << selected_style.render("    #{Styles::MARKERS[:cursor]} #{display}")
            else
              lines << dim_style.render("      #{display}")
            end
          end

          lines << dim_style.render("    #{Styles::MARKERS[:more_down]} more") if offset + visible.length < total

          lines
        end

        def render_project_editor_field(input, field_index)
          @project_editor.field_index == field_index ? selected_style.render("  #{input.view}") : "  #{input.view}"
        end

        def delete_confirm_view
          agent = @delete_confirm.agent
          dialog_width = [[@window_width - 10, 80].min, 40].max
          inner_width = [dialog_width - 4, 10].max

          title = delete_dialog_title_style.render("Delete agent?")
          question = "Are you sure you want to delete #{agent.name}?"
          excerpt_lines = @delete_confirm.excerpt.lines.map(&:chomp).map do |line|
            Bubbles::ANSI.cut_string(line, 0, inner_width)
          end
          excerpt_block = delete_dialog_excerpt_style.render(excerpt_lines.join("\n"))

          selected = @delete_confirm.picker.value
          abort_label = selected == UI::DeleteAgentConfirm::ABORT ? delete_dialog_button_selected_style.render("Abort") : delete_dialog_button_style.render("Abort")
          confirm_label = selected == UI::DeleteAgentConfirm::CONFIRM ? delete_dialog_button_selected_style.render("Confirm") : delete_dialog_button_style.render("Confirm")
          spacer = Lipgloss::Style.new.width(4).render("")
          buttons = Lipgloss.join_horizontal(:top, abort_label, spacer, confirm_label)
          hint = dim_style.render("#{Styles::KEYS[:tab]}/#{Styles::KEYS[:arrow_left]}#{Styles::KEYS[:arrow_right]}: switch  #{Styles::MARKERS[:bullet_sep]}  enter: apply  #{Styles::MARKERS[:bullet_sep]}  esc: cancel")

          body = Lipgloss.join_vertical(
            :left,
            title,
            "",
            question,
            "",
            dim_style.render("Recent chat:"),
            excerpt_block,
            "",
            Lipgloss.place_horizontal(inner_width, :center, buttons),
            "",
            hint
          )

          dialog = delete_dialog_style(dialog_width).render(body)
          Lipgloss.place(@window_width, @window_height, :center, :center, dialog)
        end

        def project_archive_confirm_view
          project = @project_archive_confirm.project
          dialog_width = [[@window_width - 10, 84].min, 44].max
          inner_width = [dialog_width - 4, 10].max

          title = delete_dialog_title_style.render("Archive project?")
          question = "Archive #{project.name} and remove it from Tycho?"
          summary_lines = @project_archive_confirm.summary.lines.map(&:chomp).map do |line|
            Bubbles::ANSI.cut_string(line, 0, inner_width)
          end
          summary_block = delete_dialog_excerpt_style.render(summary_lines.join("\n"))

          selected = @project_archive_confirm.picker.value
          abort_label = selected == UI::ProjectArchiveConfirm::ABORT ? delete_dialog_button_selected_style.render("Abort") : delete_dialog_button_style.render("Abort")
          confirm_label = selected == UI::ProjectArchiveConfirm::CONFIRM ? delete_dialog_button_selected_style.render("Archive") : delete_dialog_button_style.render("Archive")
          spacer = Lipgloss::Style.new.width(4).render("")
          buttons = Lipgloss.join_horizontal(:top, abort_label, spacer, confirm_label)
          hint = dim_style.render("#{Styles::KEYS[:tab]}/#{Styles::KEYS[:arrow_left]}#{Styles::KEYS[:arrow_right]}: switch  #{Styles::MARKERS[:bullet_sep]}  enter: apply  #{Styles::MARKERS[:bullet_sep]}  esc: cancel")

          body = Lipgloss.join_vertical(
            :left,
            title,
            "",
            question,
            "",
            summary_block,
            "",
            Lipgloss.place_horizontal(inner_width, :center, buttons),
            "",
            hint
          )

          dialog = delete_dialog_style(dialog_width).render(body)
          Lipgloss.place(@window_width, @window_height, :center, :center, dialog)
        end

        def clone_confirm_view
          new_agent = @clone_confirm.new_agent
          old_agent = @clone_confirm.old_agent
          dialog_width = [[@window_width - 10, 84].min, 44].max
          inner_width = [dialog_width - 4, 10].max

          title = delete_dialog_title_style.render("Agent cloned")
          question = "Archive #{old_agent.name} now?"
          summary_lines = @clone_confirm.summary.lines.map(&:chomp).map do |line|
            Bubbles::ANSI.cut_string(line, 0, inner_width)
          end
          summary_block = delete_dialog_excerpt_style.render(summary_lines.join("\n"))

          selected = @clone_confirm.picker.value
          keep_label = selected == UI::CloneAgentConfirm::KEEP ? delete_dialog_button_selected_style.render("Keep Old") : delete_dialog_button_style.render("Keep Old")
          archive_label = selected == UI::CloneAgentConfirm::ARCHIVE ? delete_dialog_button_selected_style.render("Archive Old") : delete_dialog_button_style.render("Archive Old")
          spacer = Lipgloss::Style.new.width(4).render("")
          buttons = Lipgloss.join_horizontal(:top, keep_label, spacer, archive_label)
          hint = dim_style.render("#{Styles::KEYS[:tab]}/#{Styles::KEYS[:arrow_left]}#{Styles::KEYS[:arrow_right]}: switch  #{Styles::MARKERS[:bullet_sep]}  enter: apply  #{Styles::MARKERS[:bullet_sep]}  esc: keep old")

          body = Lipgloss.join_vertical(
            :left,
            title,
            "",
            "Created #{new_agent.name} with fresh logs.",
            question,
            "",
            summary_block,
            "",
            Lipgloss.place_horizontal(inner_width, :center, buttons),
            "",
            hint
          )

          dialog = delete_dialog_style(dialog_width).render(body)
          Lipgloss.place(@window_width, @window_height, :center, :center, dialog)
        end

        def agent_chat_body
          agent = @agent_chat_form.agent
          project = project_for_key(agent.project_key)
          project_label = if project
                            icon_label(:project,
                                       project)
                          else
                            icon_label(:project, project_name(agent.project_key))
                          end
          prefix = horizontal_margin_prefix
          prompt_block = if @agent_chat_form.inquiry_active?
                           render_chat_inquiry_form(@agent_chat_form.inquiry_form)
                         elsif @agent_chat_form.skill_picker_open?
                           [
                             render_skill_picker(@agent_chat_form.composer.skill_picker),
                             render_chat_input_block(@agent_chat_form.composer)
                           ].reject(&:empty?).join("\n")
                         else
                           render_chat_input_block(@agent_chat_form.composer)
                         end
          summary_text = agent_chat_summary_text(agent)
          @agent_chat_form.sync_summary!(summary_text.to_s)
          @agent_chat_form.sync_summary_detail!(agent_chat_summary_detail_text(agent).to_s)
          summary_block = render_agent_chat_summary_block(summary_text)
          state_line = agent_chat_state_line(agent)
          attachment_summary = attachment_compact_summary(agent_chat_attachments(agent))
          conversation_right = [
            attachment_summary,
            @agent_chat_form.block_detail_open? ? @agent_chat_form.selected_block_detail_diagnostics : @agent_chat_form.selected_block_diagnostics
          ].compact.reject(&:empty?).join("  ")
          prompt_hint = agent_chat_prompt_hint

          sections = [
            chat_section_divider(
              label: @agent_chat_form.block_detail_open? ? @agent_chat_form.selected_block_title : "Conversation",
              focused: @agent_chat_form.content_focused?,
              right: conversation_right
            ),
            "",
            @agent_chat_form.block_detail_open? ? render_chat_block_detail : @agent_chat_form.viewport.view
          ]
          if summary_block || state_line
            sections << chat_section_divider(
              label: "Summary",
              focused: @agent_chat_form.summary_focused?,
              right: state_line,
              right_prestyled: true
            )
            if @agent_chat_form.summary_detail_open?
              sections << render_chat_summary_detail
            else
              sections << indent_block(summary_block, 2) if summary_block
            end
          end
          sections << chat_section_divider(label: "Compose", focused: @agent_chat_form.prompt_focused?)
          sections << indent_block(prompt_block, 1)
          sections << chat_section_divider
          sections << dim_style.render("#{prefix}#{prompt_hint}")

          body = sections.compact.join("\n")
          {
            title: "#{project_label} #{Styles::MARKERS[:cursor]} #{icon_label(:agent, agent)}",
            body: body
          }
        end

        def header
          nav = App::SCREENS.map.with_index(1) do |screen, index|
            label = "#{index}. #{screen.to_s.capitalize}"
            screen == @screen ? selected_tab_style.render(" #{label} ") : tab_style.render(" #{label} ")
          end.join(" ")

          latest = dim_style.render("Latest: #{icon_label(:kamal,
                                                          @latest_kamal || "?")}  #{Styles::MARKERS[:bullet_sep]}  #{icon_label(:rails,
                                                                                                  @latest_rails || "?")}")
          [
            title_style.render("Tycho - Ops Cockpit"),
            join_left_right(nav, latest)
          ].join("\n")
        end

        def main_screen_view
          header_block = header
          footer_block = footer
          body_lines = [@window_height - line_count(header_block) - line_count(footer_block) - 2, 4].max

          right = overlay_open? ? sidebar_view : right_panel_view
          right_block = pad_block_lines(trim_block_lines(right, body_lines), body_lines)

          if sidebar_visible?
            list_block = pad_block_lines(trim_block_lines(list_sidebar_view(body_lines), body_lines), body_lines)
            split = Lipgloss.join_horizontal(:top, list_block, " " * split_gap_width, right_block)
          else
            split = right_block
          end

          screen = [header_block, "", split, "", footer_block].join("\n")
          screen = render_agent_attachments_overlay(screen) if agent_chat_attachments_open?
          omnisearch_open? ? render_omnisearch_overlay(screen) : screen
        end

        def right_panel_view
          render_detail_card(current_detail_text)
        end

        def list_sidebar_view(max_lines = list_body_height)
          body = case @screen
                 when :agents then agent_list_items(max_lines: list_items_height(max_lines))
                 when :projects then project_list_items(max_lines: list_items_height(max_lines))
                 when :schedules then schedule_list_items(max_lines: list_items_height(max_lines))
                 else ""
                 end
          sections = [title_style.render(list_title), "", body]
          legend = list_legend_block
          remaining_lines = [max_lines.to_i - 2, 1].max - line_count(sections.join("\n"))
          if legend && remaining_lines >= line_count(legend) + 1
            sections << ""
            sections << legend
          end
          list_card_style.render(sections.join("\n"))
        end

        def list_title
          case @screen
          when :agents then icon_label(:agent, "Agents")
          when :projects then icon_label(:project, "Projects")
          when :schedules then icon_label(:clock, "Schedules")
          else ""
          end
        end

        def list_legend_block
          if @screen == :agents && !@agents.empty?
            agent_status_legend_block(list_content_width)
          elsif @screen == :projects && !@projects.empty?
            project_status_legend_block(list_content_width)
          elsif @screen == :schedules && !@schedules.empty?
            schedule_status_legend_block(list_content_width)
          end
        end

        def list_items_height(max_lines)
          max_inner_lines = [max_lines.to_i - 2, 1].max
          [max_inner_lines - 2, 1].max
        end

        def agent_list_items(max_lines: nil)
          width = list_content_width
          return empty_agent_list_items(width) if @agents.empty?

          lines = []
          current_group = nil
          selected_line = 0
          @agents.each_with_index do |agent, index|
            group = project_name(agent.project_key) || "Unlinked"
            if group != current_group
              lines << "" unless lines.empty?
              lines << selected_tab_style.render(" #{icon_label(:project, truncate(group, width - 5))} ")
              current_group = group
            end

            selected = index == @selected[:agents]
            status_icon = styled_agent_status_icon(agent.status, spinner: true)
            name_budget = [width - 6, 1].max
            label = icon_label(:agent, truncate(agent.name.to_s, name_budget))
            cursor = selected ? Styles::MARKERS[:cursor] : " "
            unread_marker = agent.unread? ? Styles::MARKERS[:unread] : " "
            row = " #{cursor}#{unread_marker} #{status_icon} #{label}"
            selected_line = lines.length if selected
            lines << (selected ? selected_style.render(pad_visible(row, width)) : row)
          end
          visible_list_lines(lines, selected_line, max_lines).join("\n")
        end

        def project_list_items(max_lines: nil)
          width = list_content_width
          return empty_project_list_items(width) if @projects.empty?

          lines = []
          current_group = nil
          selected_line = 0
          @projects.each_with_index do |project, index|
            group = project.group.to_s.strip
            if !group.empty? && group != current_group
              lines << "" unless lines.empty?
              lines << selected_tab_style.render(" #{icon_label(:group, truncate(group, width - 5))} ")
              current_group = group
            end

            selected = index == @selected[:projects]
            status_icon = styled_project_status_icon(project, spinner: true)
            name_budget = [width - 6, 1].max
            label = icon_label(:project, project, label: truncate(project.name.to_s, name_budget))
            cursor = selected ? Styles::MARKERS[:cursor] : " "
            row = " #{cursor} #{status_icon} #{label}"
            selected_line = lines.length if selected
            lines << (selected ? selected_style.render(pad_visible(row, width)) : row)
          end
          visible_list_lines(lines, selected_line, max_lines).join("\n")
        end

        def schedule_list_items(max_lines: nil)
          width = list_content_width
          return empty_schedule_list_items(width) if @schedules.empty?

          lines = []
          selected_line = 0
          @schedules.each_with_index do |schedule, index|
            selected = index == @selected[:schedules]
            status_icon = styled_schedule_status_icon(schedule)
            name_budget = [width - 6, 1].max
            label = icon_label(:clock, truncate(schedule[:name].to_s.empty? ? schedule[:key].to_s : schedule[:name].to_s, name_budget))
            cursor = selected ? Styles::MARKERS[:cursor] : " "
            row = " #{cursor} #{status_icon} #{label}"
            selected_line = lines.length if selected
            lines << (selected ? selected_style.render(pad_visible(row, width)) : row)
          end
          visible_list_lines(lines, selected_line, max_lines).join("\n")
        end

        def empty_agent_list_items(width)
          hint = if @projects.empty?
                   "Press 2, then N to create a project."
                 else
                   "Press 2, then n to create one."
                 end
          [
            "No managed agents yet.",
            hint
          ].map { |line| dim_style.render(truncate(line, width)) }.join("\n")
        end

        def empty_project_list_items(width)
          [
            "No projects configured.",
            "Press N to create one."
          ].map { |line| dim_style.render(truncate(line, width)) }.join("\n")
        end

        def empty_schedule_list_items(width)
          lines = @schedule_error ? ["Schedule config error.", @schedule_error] : ["No schedules configured.", "Create config/schedules.yml."]
          lines.map { |line| dim_style.render(truncate(line, width)) }.join("\n")
        end

        def project_pr_indicator(project)
          return [nil, nil] unless project.respond_to?(:pr_url) && project.pr_url

          number = project.respond_to?(:pr_number) ? project.pr_number : nil
          label = number ? "#{Styles::ICONS[:pr]}#{number}" : "#{Styles::ICONS[:pr]}PR"
          [label, "\e]8;;#{project.pr_url}\e\\#{label}\e]8;;\e\\"]
        end

        def visible_list_lines(lines, selected_line, max_lines)
          return lines if max_lines.nil?

          height = [max_lines.to_i, 1].max
          return lines if lines.length <= height

          selected_line = [[selected_line.to_i, 0].max, lines.length - 1].min
          offset = selected_line - height + 1
          offset = [[offset, 0].max, lines.length - height].min
          lines[offset, height] || []
        end

        def render_omnisearch_overlay(base)
          render_floating_overlay(base, render_omnisearch_card)
        end

        def render_agent_attachments_overlay(base)
          render_floating_overlay(base, render_agent_attachments_card)
        end

        def render_floating_overlay(base, overlay)
          overlay_lines = overlay.split("\n", -1)
          overlay_width = overlay_lines.map { |line| visible_width(line) }.max || 0
          overlay_height = overlay_lines.length
          top = [[(@window_height - overlay_height) / 3, 2].max, @window_height - overlay_height].min
          max_left = [@window_width - overlay_width, 0].max
          left = [[(@window_width - overlay_width) / 2, 0].max, max_left].min

          base_lines = base.split("\n", -1)
          base_lines += Array.new(@window_height - base_lines.length, "") if base_lines.length < @window_height

          overlay_lines.each_with_index do |overlay_line, index|
            row = top + index
            next if row.negative? || row >= base_lines.length

            base_line = base_lines[row].to_s
            left_part = Bubbles::ANSI.cut_string(base_line, 0, left)
            right_part = Bubbles::ANSI.cut_string(base_line, left + overlay_width, @window_width)
            base_lines[row] = "#{pad_visible(left_part, left)}#{pad_visible(overlay_line, overlay_width)}#{right_part}"
          end

          base_lines.first(@window_height).join("\n")
        end

        def agent_chat_attachments_open?
          @sidebar&.fetch(:kind, nil) == :agent_chat && @agent_chat_form&.attachments_detail_open?
        end

        def render_agent_attachments_card
          width = [[@window_width - 4, 72].min, 20].max
          inner_width = [width - 4, 20].max
          result_height = [[@window_height - 12, 3].max, 12].min
          attachments = agent_chat_attachments(@agent_chat_form&.agent)
          @agent_chat_form&.sync_attachment_items!(attachments)
          @agent_chat_form&.sync_attachments!(
            agent_chat_attachments_text(
              attachments,
              selected_index: @agent_chat_form&.selected_attachment_index,
              width: inner_width
            ),
            width: inner_width,
            height: result_height
          )

          title = title_style.render("Attachments")
          summary = attachment_compact_summary(attachments)
          subtitle = summary ? dim_style.render(summary) : dim_style.render("No saved attachments")
          hint = dim_style.render("#{Styles::KEYS[:arrow_up]}#{Styles::KEYS[:arrow_down]}: move  #{Styles::MARKERS[:bullet_sep]}  enter: open  #{Styles::MARKERS[:bullet_sep]}  #{Styles::KEYS[:ctrl]}A/esc: close")

          body = Lipgloss.join_vertical(
            :left,
            title,
            subtitle,
            "",
            @agent_chat_form&.attachments_viewport&.view.to_s,
            "",
            hint
          )
          omnisearch_dialog_style(width).render(body)
        end

        def render_omnisearch_card
          width = [[@window_width - 4, 72].min, 20].max
          inner_width = [width - 4, 20].max
          result_height = [[@window_height - 12, 3].max, 8].min
          results, result_offset = visible_omnisearch_results(result_height)

          title = title_style.render("Omnisearch")
          prompt = @omnisearch.query.empty? ? dim_style.render("Unread agents") : @omnisearch.query
          input = omnisearch_input_style.render("#{Styles::MARKERS[:cursor]} #{prompt}")
          result_lines = if results.empty?
                           [dim_style.render(@omnisearch.empty_query? ? "No unread agents" : "No matches")]
                         else
                           results.map.with_index do |item, index|
                             selected = result_offset + index == @omnisearch.selected_index
                             marker = selected ? Styles::MARKERS[:cursor] : " "
                             unread = item.unread ? Styles::MARKERS[:unread] : " "
                             icon = item.type == :agent ? Styles::ICONS[:agent] : Styles::ICONS[:project]
                             display = omnisearch_item_display(item)
                             label = truncate(display, [inner_width - 8, 1].max)
                             row = " #{marker}#{unread} #{icon} #{label}"
                             selected ? selected_style.render(pad_visible(row, inner_width)) : row
                           end
                         end
          hint = dim_style.render("#{Styles::KEYS[:arrow_up]}#{Styles::KEYS[:arrow_down]}: move  #{Styles::MARKERS[:bullet_sep]}  enter: select  #{Styles::MARKERS[:bullet_sep]}  esc: close")

          body = Lipgloss.join_vertical(
            :left,
            title,
            input,
            "",
            *result_lines,
            "",
            hint
          )
          omnisearch_dialog_style(width).render(body)
        end

        def omnisearch_item_display(item)
          return item.label unless item.type == :agent
          return item.label if item.detail.to_s.empty?

          "#{item.label} #{Styles::MARKERS[:bullet_sep]} #{item.detail}"
        end

        def visible_omnisearch_results(height)
          results = @omnisearch.results
          return [[], 0] if results.empty?
          return [results, 0] if results.length <= height

          selected = [[@omnisearch.selected_index, 0].max, results.length - 1].min
          offset = selected - height + 1
          offset = [[offset, 0].max, results.length - height].min
          [results[offset, height] || [], offset]
        end

        def detail_full_view
          body = @detail_viewport&.view.to_s
          hint = dim_style.render("j/k/g/G #{Styles::KEYS[:arrow_up]}/#{Styles::KEYS[:arrow_down]}: scroll  #{Styles::MARKERS[:bullet_sep]}  r: refresh  #{Styles::MARKERS[:bullet_sep]}  esc/q/v: close")
          content = [
            title_style.render(detail_overlay_title),
            "",
            body,
            "",
            hint
          ].join("\n")
          dialog = detail_overlay_style.render(content)
          Lipgloss.place(@window_width, @window_height, :center, :center, dialog)
        end

        def detail_overlay_title
          case @screen
          when :agents then "Agent Detail"
          when :projects then "Project Detail"
          when :schedules then "Schedule Detail"
          else "Detail"
          end
        end

        def footer
          if @confirming
            if @confirming == :restart
              return footer_confirm_style.render(truncate("Restart Tycho? (y/n)", footer_content_width))
            end

            if @confirming == :quit
              return footer_confirm_style.render(truncate("Quit Tycho? (y/n)", footer_content_width))
            end

            if @confirming == :rebuild_memory
              return footer_confirm_style.render(truncate("Rebuild conversation and summary? (y/n)", footer_content_width))
            end

            project = selected_project
            action_name = if @confirming == :maintenance && project&.app_status == "maintenance"
                            "Set live"
                          else
                            @confirming.to_s
                          end
            return footer_confirm_style.render(truncate("#{action_name} #{project&.name}? (y/n)", footer_content_width))
          end

          refresh_text = @last_refresh ? "Last refresh: #{@last_refresh.strftime("%H:%M:%S")}" : "Loading..."
          loading_text = @loading ? " (refreshing...)" : ""
          sidebar_hint_text = "#{Styles::KEYS[:ctrl]}B: #{sidebar_visible? ? "hide" : "show"} sidebar"
          hint = case @screen
                 when :agents then "#{Styles::KEYS[:tab]}/1-3: switch  #{Styles::MARKERS[:bullet_sep]}  j/k: nav  #{Styles::MARKERS[:bullet_sep]}  v: detail  #{Styles::MARKERS[:bullet_sep]}  #{sidebar_hint_text}  #{Styles::MARKERS[:bullet_sep]}  #{Styles::KEYS[:ctrl]}G: term  #{Styles::MARKERS[:bullet_sep]}  #{Styles::KEYS[:ctrl]}T: agent term  #{Styles::MARKERS[:bullet_sep]}  c/C: chat/clone  #{Styles::MARKERS[:bullet_sep]}  s: start  #{Styles::MARKERS[:bullet_sep]}  R: rerun  #{Styles::MARKERS[:bullet_sep]}  t: stop  #{Styles::MARKERS[:bullet_sep]}  e: edit  #{Styles::MARKERS[:bullet_sep]}  x: delete  #{Styles::MARKERS[:bullet_sep]}  l/L: log  #{Styles::MARKERS[:bullet_sep]}  r: refresh  #{Styles::MARKERS[:bullet_sep]}  #{Styles::KEYS[:ctrl]}R: restart  #{Styles::MARKERS[:bullet_sep]}  q: quit"
                 when :projects then "#{Styles::KEYS[:tab]}/1-3: switch  #{Styles::MARKERS[:bullet_sep]}  j/k: nav  #{Styles::MARKERS[:bullet_sep]}  v: detail  #{Styles::MARKERS[:bullet_sep]}  #{sidebar_hint_text}  #{Styles::MARKERS[:bullet_sep]}  #{Styles::KEYS[:ctrl]}G: term  #{Styles::MARKERS[:bullet_sep]}  n: new agent  #{Styles::MARKERS[:bullet_sep]}  N: new project  #{Styles::MARKERS[:bullet_sep]}  d: deploy  #{Styles::MARKERS[:bullet_sep]}  m: maint  #{Styles::MARKERS[:bullet_sep]}  x: archive  #{Styles::MARKERS[:bullet_sep]}  l: log  #{Styles::MARKERS[:bullet_sep]}  h: health  #{Styles::MARKERS[:bullet_sep]}  r: refresh  #{Styles::MARKERS[:bullet_sep]}  #{Styles::KEYS[:ctrl]}R: restart  #{Styles::MARKERS[:bullet_sep]}  q: quit"
                 when :schedules then "#{Styles::KEYS[:tab]}/1-3: switch  #{Styles::MARKERS[:bullet_sep]}  j/k: nav  #{Styles::MARKERS[:bullet_sep]}  v: detail  #{Styles::MARKERS[:bullet_sep]}  #{sidebar_hint_text}  #{Styles::MARKERS[:bullet_sep]}  r: refresh  #{Styles::MARKERS[:bullet_sep]}  #{Styles::KEYS[:ctrl]}R: restart  #{Styles::MARKERS[:bullet_sep]}  q: quit"
                 end
          hint = "esc: close  #{Styles::MARKERS[:bullet_sep]}  #{hint}" if overlay_open?

          footer_style.render(truncate("#{refresh_text}#{loading_text}  #{Styles::MARKERS[:bullet_sep]}  #{hint}", footer_content_width))
        end

        def current_detail_text
          case @screen
          when :agents then agent_detail_text
          when :projects then project_detail_text
          when :schedules then schedule_detail_text
          else "No detail available"
          end
        end

        def schedule_detail_text
          width = detail_content_width
          lines = []
          daemon = @schedule_daemon || {}
          daemon_status = daemon[:status].to_s.empty? ? "unknown" : daemon[:status].to_s

          lines << "#{Styles::ICONS[:clock]} #{title_mini("Scheduler")}"
          lines << format_detail_row("Daemon", daemon_status)
          lines << format_detail_row("PID", daemon[:pid] || "n/a")
          lines << format_detail_row("Mode", daemon[:mode] || "n/a")
          lines << format_detail_row("Last tick", daemon[:last_tick_finished_at] || "n/a")
          lines << format_detail_row("Last error", daemon[:last_error] || "n/a")
          lines << ""

          if @schedule_error
            lines << fail_style.render("Schedule config error")
            lines << wrap_text(@schedule_error, width)
            return lines.join("\n")
          end

          schedule = selected_schedule
          unless schedule
            lines << dim_style.render("No schedules configured.")
            return lines.join("\n")
          end

          lines << "#{Styles::ICONS[:clock]} #{title_mini(schedule[:name].to_s.empty? ? schedule[:key].to_s : schedule[:name].to_s)}"
          lines << format_detail_row("Key", schedule[:key])
          lines << format_detail_row("Project", schedule[:project_key])
          lines << format_detail_row("Cron", schedule[:cron])
          lines << format_detail_row("Timezone", schedule[:timezone])
          lines << format_detail_row("Paused", schedule[:paused] ? "yes" : "no")
          lines << format_detail_row("Next", schedule[:next_due_at] || "n/a")
          lines << format_detail_row("Last status", schedule[:last_status] || "n/a")
          lines << format_detail_row("Last error", schedule[:last_error] || "n/a")
          lines << format_detail_row("Last agent", schedule[:last_target_key] || "n/a")
          lines << format_detail_row("Runs", schedule[:run_count].to_i.to_s)
          lines << format_detail_row("Skips", schedule[:skip_count].to_i.to_s)
          lines.join("\n")
        end

        def agent_detail_text
          agent = selected_agent
          return empty_agent_detail_text unless agent

          project = project_for_key(agent.project_key)
          width = detail_content_width
          divider = dim_style.render(Styles::BOX[:h] * width)

          lines = []
          lines.concat(detail_hero_block(agent, project))
          lines << ""
          lines << divider
          lines << ""
          lines.concat(detail_run_result_block(agent))
          lines << ""
          lines.concat(detail_prose_block(:summary, agent.last_summary)) if agent.last_summary.to_s.strip != ""
          lines << "" if agent.last_summary.to_s.strip != ""
          lines.concat(detail_prose_block(:prompt, agent.prompt)) if agent.prompt.to_s.strip != ""
          lines << "" if agent.prompt.to_s.strip != ""
          lines << divider
          lines << ""
          lines.concat(detail_footer_meta(agent))
          lines << ""
          lines << divider
          lines << ""
          lines << footer_style.render("c: chat  #{Styles::MARKERS[:bullet_sep]}  C: clone  #{Styles::MARKERS[:bullet_sep]}  s: start  #{Styles::MARKERS[:bullet_sep]}  R: rerun  #{Styles::MARKERS[:bullet_sep]}  t: stop  #{Styles::MARKERS[:bullet_sep]}  #{Styles::KEYS[:ctrl]}T: agent term  #{Styles::MARKERS[:bullet_sep]}  e: edit  #{Styles::MARKERS[:bullet_sep]}  x: delete  #{Styles::MARKERS[:bullet_sep]}  l: chat log  #{Styles::MARKERS[:bullet_sep]}  L: raw log")
          lines.join("\n")
        end

        def empty_agent_detail_text
          lines = [
            "No managed agent selected",
            ""
          ]
          if @projects.empty?
            lines << "No projects are configured."
            lines << "Press 2, then N to create a project."
          else
            lines << "No managed agents are available."
            lines << "Press 2, select a project, then n to create an agent."
          end
          lines.join("\n")
        end

        def detail_hero_block(agent, project)
          width = detail_content_width
          lines = []
          name_line = "#{Styles::ICONS[:agent]}  #{agent.name}"
          status = styled_agent_status(agent.status, spinner: true)
          status_width = visible_width(status)
          name_budget = [width - status_width - 2, 10].max
          name_line = truncate_display(name_line, name_budget)
          gap = [width - visible_width(name_line) - status_width, 1].max
          lines << "#{name_line}#{" " * gap}#{status}"
          crumb = [project&.name, agent.template_key, agent.agent].compact.reject { |s| s.to_s.empty? }.join(" · ")
          lines << "#{Styles::ICONS[:project]}  #{dim_style.render(crumb)}" unless crumb.empty?

          chips = agent_chip_row(agent, project)
          unless chips.empty?
            lines << ""
            lines << chips
          end
          lines
        end

        def agent_chip_row(_agent, project)
          return "" unless project

          parts = []
          if project.pr_number && project.pr_url
            parts << chip(Styles::ICONS[:github], "##{project.pr_number}", url: project.pr_url)
          end
          if project.branch
            parts << chip(Styles::ICONS[:branch], project.branch, url: project.branch_url(project.branch))
          end
          if project.commit_hash
            short = project.commit_hash.to_s[0, 7]
            parts << chip(Styles::ICONS[:commit], short, url: project.commit_url(project.commit_hash))
          end
          git_clean = project.dirty_files.to_i.positive? ? "#{project.dirty_files} dirty" : "clean"
          git_style = project.dirty_files.to_i.positive? ? warning_style : success_style
          parts << git_style.render(git_clean)
          parts.join("   ")
        end

        def detail_run_result_block(agent)
          width = detail_content_width
          col_width = [(width / 2) - 1, 20].max

          started = agent.started_at ? format_time(agent.started_at) : "n/a"
          finished = agent.finished_at ? format_time(agent.finished_at) : "n/a"
          elapsed = detail_elapsed(agent)
          run_rows = [
            ["Started", started],
            ["Finished", finished],
            ["Elapsed", elapsed || "n/a"]
          ]

          result_rows = [
            ["Runs", agent.run_count.to_s],
            ["Exit", agent.last_exit_code.nil? ? "n/a" : agent.last_exit_code.to_s],
            ["Last", agent.last_result_label.to_s]
          ]

          lines = []
          run_header = "#{Styles::ICONS[:run]} #{title_mini("Run")}"
          result_header = "#{Styles::ICONS[:result]} #{title_mini("Result")}"
          lines << "#{pad_visible(run_header, col_width)}#{result_header}"
          run_rows.zip(result_rows).each do |left_row, right_row|
            left = format_detail_row(left_row[0], left_row[1])
            right = format_detail_row(right_row[0], right_row[1])
            lines << "#{pad_visible(left, col_width)}#{right}"
          end
          lines
        end

        def detail_elapsed(agent)
          return nil unless agent.started_at
          return nil unless agent.finished_at

          seconds = (agent.finished_at - agent.started_at).to_i
          return nil if seconds.negative?
          return "#{seconds}s" if seconds < 60
          return "#{seconds / 60}m #{seconds % 60}s" if seconds < 3600

          "#{seconds / 3600}h #{(seconds % 3600) / 60}m"
        end

        def title_mini(text)
          dim_style.render(text.to_s)
        end

        def format_detail_row(label, value)
          "  #{dim_style.render(label.to_s.ljust(10))}#{value}"
        end

        def detail_prose_block(kind, body)
          icon = Styles::ICONS[kind]
          heading = kind.to_s.capitalize
          # Icon hangs one column to the left of the body's left edge so
          # that the first letter of the heading stacks above the first
          # letter of the body.
          body_indent = "  "
          lines = ["#{icon} #{title_mini(heading)}"]
          wrapped = wrap_text(body.to_s.strip, detail_content_width - body_indent.length)
          wrapped.split("\n").each { |line| lines << "#{body_indent}#{line}" }
          lines
        end

        def detail_footer_meta(agent)
          width = detail_content_width
          rows = []
          rows << [:workspace, "Workspace", agent.workspace.to_s, :path]
          rows << [:session, "Session", agent.session_id.to_s.empty? ? "n/a" : agent.session_id.to_s, :text]
          rows << [:log, "Raw Log", agent.raw_log_path.to_s, :path]
          rows << [:sandbox, "Sandbox", agent.sandbox_mode.to_s, :text]
          rows << [:clock, "Created", format_time(agent.created_at), :text]

          rows.map do |icon_key, label, value, kind|
            prefix = "#{Styles::ICONS[icon_key]} #{dim_style.render(label.ljust(10))}"
            prefix_width = visible_width(prefix)
            budget = [width - prefix_width, 10].max
            rendered_value = case kind
                             when :path then render_path_value(value, budget)
                             else truncate_display(value, budget)
                             end
            prefix + rendered_value
          end
        end

        # Collapse a filesystem path into a single line that fits `budget`
        # visible columns. If the path is short enough, return as-is wrapped
        # in an OSC 8 file:// hyperlink. Otherwise middle-truncate with `…`,
        # keeping both ends visible, and wrap the (abbreviated) label in the
        # hyperlink so clicking still opens the real path.
        def render_path_value(path, budget)
          str = path.to_s
          home = ENV["HOME"].to_s
          display = !home.empty? && str.start_with?("#{home}/") ? str.sub(home, "~") : str
          display = middle_truncate(display, budget)
          file_url = "file://#{str.start_with?("/") ? str : File.expand_path(str)}"
          osc8_link(file_url, display)
        end

        def middle_truncate(text, width)
          text = text.to_s
          return text if visible_width(text) <= width
          return "…" if width <= 1

          keep = width - 1
          head_chars = keep / 2
          tail_chars = keep - head_chars
          "#{text[0, head_chars]}…#{text[-tail_chars, tail_chars]}"
        end

        def truncate_display(text, width)
          truncate(text.to_s, width)
        end

        def project_detail_text
          project = selected_project
          return empty_project_detail_text unless project

          width = detail_content_width
          divider = dim_style.render(Styles::BOX[:h] * width)

          lines = []
          lines.concat(project_hero_block(project))
          lines << ""
          lines << divider
          if project.apps_enabled?
            lines << ""
            lines.concat(project_service_health_block(project))
          end
          lines << ""
          lines << divider
          lines << ""
          lines.concat(project_footer_meta(project))

          action_block = project_action_block(project)
          unless action_block.empty?
            lines << ""
            lines << divider
            lines << ""
            lines.concat(action_block)
          end

          recent = project_recent_agent_block(project)
          unless recent.empty?
            lines << ""
            lines << divider
            lines << ""
            lines.concat(recent)
          end

          lines << ""
          lines << divider
          lines << ""
          lines << footer_style.render("d: deploy  #{Styles::MARKERS[:bullet_sep]}  m: maint  #{Styles::MARKERS[:bullet_sep]}  h: health  #{Styles::MARKERS[:bullet_sep]}  r: refresh  #{Styles::MARKERS[:bullet_sep]}  #{Styles::KEYS[:ctrl]}G: term  #{Styles::MARKERS[:bullet_sep]}  n: new agent  #{Styles::MARKERS[:bullet_sep]}  l: log  #{Styles::MARKERS[:bullet_sep]}  x: archive")
          lines.join("\n")
        end

        def empty_project_detail_text
          [
            "No project selected",
            "",
            "No projects are configured.",
            "Press N to create a new project."
          ].join("\n")
        end

        def project_hero_block(project)
          width = detail_content_width
          lines = []
          icon_key = project.apps_enabled? ? :web_project : :project
          name_line = "#{Styles::ICONS[icon_key]}  #{project.name}"
          status = project.apps_enabled? ? status_text_for(project) : dim_style.render("not an app")
          status_width = visible_width(status)
          name_budget = [width - status_width - 2, 10].max
          name_line = truncate_display(name_line, name_budget)
          gap = [width - visible_width(name_line) - status_width, 1].max
          lines << "#{name_line}#{" " * gap}#{status}"
          crumb = [project.group, project.key].compact.reject { |s| s.to_s.empty? }.uniq.join(" · ")
          lines << "#{Styles::ICONS[:group]}  #{dim_style.render(crumb)}" unless crumb.empty?

          chips = project_chip_row(project)
          unless chips.empty?
            lines << ""
            lines << chips
          end
          lines
        end

        def project_chip_row(project)
          parts = []
          if project.pr_number && project.pr_url
            parts << chip(Styles::ICONS[:github], "##{project.pr_number}", url: project.pr_url)
          end
          if project.branch
            parts << chip(Styles::ICONS[:branch], project.branch, url: project.branch_url(project.branch))
          end
          if project.commit_hash
            short = project.commit_hash.to_s[0, 7]
            parts << chip(Styles::ICONS[:commit], short, url: project.commit_url(project.commit_hash))
          end
          git_clean = project.dirty_files.to_i.positive? ? "#{project.dirty_files} dirty" : "clean"
          git_style = project.dirty_files.to_i.positive? ? warning_style : success_style
          parts << git_style.render(git_clean)
          parts.join("   ")
        end

        def project_service_health_block(project)
          width = detail_content_width
          col_width = [(width / 2) - 1, 20].max

          hosts = Array(project.hosts).map { |host| obfuscate_ip(host) }.join(", ")
          service_rows = [
            ["Service", project.service.to_s.empty? ? "n/a" : project.service.to_s],
            ["Image", project.image.to_s.empty? ? "n/a" : project.image.to_s],
            ["Hosts", hosts.empty? ? "n/a" : hosts],
            ["Proxy", project.proxy_host.to_s.empty? ? "n/a" : project.proxy_host.to_s]
          ]

          latency = project.response_time ? "#{project.response_time}ms" : "n/a"
          health_rows = [
            ["Status", project.health_status.to_s],
            ["Latency", latency],
            ["Health", project.healthcheck_path.to_s.empty? ? "n/a" : project.healthcheck_path.to_s],
            ["Versions", "kamal #{project.kamal_version || "?"} · rails #{project.rails_version || "?"}"]
          ]

          lines = []
          service_header = "#{Styles::ICONS[:kamal]} #{title_mini("Service")}"
          health_header = "#{Styles::ICONS[:rails]} #{title_mini("Health")}"
          lines << "#{pad_visible(service_header, col_width)}#{health_header}"
          service_rows.zip(health_rows).each do |left_row, right_row|
            left = format_detail_row(left_row[0], left_row[1])
            right = format_detail_row(right_row[0], right_row[1])
            lines << "#{pad_visible(left, col_width)}#{right}"
          end
          lines
        end

        def project_footer_meta(project)
          width = detail_content_width
          templates = project.agent_templates.map(&:name).join(", ")
          templates = "none" if templates.empty?
          agents_count = @agents_by_project[project.key].length

          rows = []
          rows << [:workspace, "Path", project.path.to_s, :path]
          rows << [:log, "Log Dir", project.log_dir.to_s, :path]
          rows << [:log, "Action Log", project.action_log_path.to_s, :path]
          rows << [:template, "Templates", templates, :text]
          rows << [:agent, "Agents", agents_count.to_s, :text]

          rows.map do |icon_key, label, value, kind|
            prefix = "#{Styles::ICONS[icon_key]} #{dim_style.render(label.ljust(10))}"
            prefix_width = visible_width(prefix)
            budget = [width - prefix_width, 10].max
            rendered_value = case kind
                             when :path then render_path_value(value, budget)
                             else truncate_display(value, budget)
                             end
            prefix + rendered_value
          end
        end

        def project_action_block(project)
          width = detail_content_width
          lines = []
          if @actions.key?(project.key)
            action = @actions[project.key]
            elapsed = "#{(Time.now - action.started_at).to_i}s"
            lines << "#{Styles::ICONS[:run]} #{title_mini("Action")}"
            lines << format_detail_row("Running", "#{@spinner.view} #{action.label} (#{elapsed})")
            prefix = "#{Styles::ICONS[:log]} #{dim_style.render("Log".ljust(10))}"
            budget = [width - visible_width(prefix), 10].max
            lines << prefix + render_path_value(action.log_path.to_s, budget)
          elsif (result = @action_results[project.key]) && UI::Rendering::ProjectStatusBadge.result_active?(result)
            lines << "#{Styles::ICONS[:result]} #{title_mini("Last Action")}"
            lines << format_detail_row("Result", project_action_result_label(result))
            if result[:log_path]
              prefix = "#{Styles::ICONS[:log]} #{dim_style.render("Log".ljust(10))}"
              budget = [width - visible_width(prefix), 10].max
              lines << prefix + render_path_value(result[:log_path].to_s, budget)
            end
          end
          lines
        end

        def project_recent_agent_block(project)
          agent = @agents_by_project[project.key].first
          return [] unless agent

          lines = []
          status = styled_agent_status(agent.status, spinner: true)
          status_width = visible_width(status)
          name_line = "#{Styles::ICONS[:agent]}  #{agent.name}"
          width = detail_content_width
          name_budget = [width - status_width - 2, 10].max
          name_line = truncate_display(name_line, name_budget)
          gap = [width - visible_width(name_line) - status_width, 1].max
          lines << "#{name_line}#{" " * gap}#{status}"
          lines << "#{Styles::ICONS[:result]}  #{dim_style.render(agent.last_result_label.to_s)}"
          summary = agent.last_summary.to_s.strip
          unless summary.empty?
            lines << ""
            lines.concat(detail_prose_block(:summary, summary))
          end
          lines
        end

        def project_action_result_label(result)
          action = result[:action_label] || KamalAction.label_for(result[:action])
          status = result[:success] ? "success" : "failed"
          "#{action} - #{status}"
        end

        def group_row(name)
          "#{horizontal_margin_prefix}#{selected_tab_style.render(" #{name} ")}"
        end

        def render_detail_card(text)
          # Lipgloss strips OSC 8 hyperlink escape sequences when wrapping
          # to .width(...). Replace each hyperlink with just its visible
          # label for rendering, recording the (label, full-escape) pair,
          # then swap the escape back in on the rendered output so the
          # terminal receives clickable hyperlinks. Because the label has
          # the same visible width as the hyperlink, Lipgloss layout is
          # preserved.
          links = []
          sentineled = text.gsub(/\e\]8;;([^\e]*)\e\\([^\e]*)\e\]8;;\e\\/) do
            url = Regexp.last_match(1)
            label = Regexp.last_match(2)
            links << [label, "\e]8;;#{url}\e\\#{label}\e]8;;\e\\"]
            label
          end
          rendered = detail_style.render(sentineled)
          links.each do |label, escape|
            rendered = rendered.sub(label, escape)
          end
          rendered
        end

        def sidebar_view
          body = case @sidebar[:kind]
                 when :agent_editor
                   agent_editor_body
                 when :project_editor
                   project_editor_body
                 when :agent_chat
                   agent_chat = agent_chat_body
                   return render_agent_chat_card(agent_chat[:title], agent_chat[:body])
                 else
                   sidebar_text_body
                 end

          render_sidebar_card(sidebar_title, body)
        end

        def render_sidebar_card(title, body)
          sidebar_style.render([
            title_style.render(title),
            "",
            body
          ].join("\n"))
        end

        def render_agent_chat_card(title, body)
          rendered = chat_sidebar_style.render([
            title_style.render(title),
            "",
            body
          ].join("\n"))
          rewrite_chat_divider_lines(rendered)
        end

        def rewrite_chat_divider_lines(rendered)
          ansi_re = /\e\[[\d;]*m/
          sentinel = ChatRendering::CHAT_DIVIDER_SENTINEL
          flush_sentinel = ChatRendering::CHAT_DIVIDER_FLUSH_SENTINEL
          right_flush_sentinel = ChatRendering::CHAT_DIVIDER_RIGHT_FLUSH_SENTINEL
          border = chat_border_style
          rendered.each_line.map do |line|
            chomped = line.chomp
            if chomped.include?(flush_sentinel)
              chomped
                .sub(flush_sentinel, "")
                .sub(/\A((?:#{ansi_re.source})*)│((?:#{ansi_re.source})*) /, "\\1├\\2#{border.render("─")}")
                .sub(/ ((?:#{ansi_re.source})*)│((?:#{ansi_re.source})*)\z/, "#{border.render("─")}\\1┤\\2")
            elsif chomped.include?(right_flush_sentinel)
              chomped
                .sub(right_flush_sentinel, "")
                .sub(/\A((?:#{ansi_re.source})*)│((?:#{ansi_re.source})*)/, '\1├\2')
                .sub(/ ((?:#{ansi_re.source})*)│((?:#{ansi_re.source})*)\z/, "#{border.render("─")}\\1┤\\2")
            elsif chomped.include?(sentinel)
              chomped
                .sub(sentinel, "")
                .sub(/\A((?:#{ansi_re.source})*)│((?:#{ansi_re.source})*)/, '\1├\2')
                .sub(/((?:#{ansi_re.source})*)│((?:#{ansi_re.source})*)\z/, '\1┤\2')
            else
              chomped
            end
          end.join("\n")
        end

        def sidebar_text_body
          body = @sidebar_viewport&.view.to_s
          hint = dim_style.render(sidebar_hint)
          [body, "", hint].join("\n")
        end

        def sidebar_title
          @sidebar[:title]
        end

        def sidebar_hint
          return "" unless @sidebar

          case @sidebar[:kind]
          when :agent_detail, :project_detail
            "j/k/g/G #{Styles::KEYS[:arrow_up]}/#{Styles::KEYS[:arrow_down]}: scroll  #{Styles::MARKERS[:bullet_sep]}  esc: close"
          when :chat_log, :raw_log, :project_log, :healthcheck_log
            total_lines = @sidebar_viewport ? @sidebar_viewport.total_line_count : 0
            current_line = total_lines.zero? ? 0 : @sidebar_viewport.y_offset + 1
            "line #{current_line}/#{total_lines}  #{Styles::MARKERS[:bullet_sep]}  h/l #{Styles::KEYS[:arrow_left]}/#{Styles::KEYS[:arrow_right]}: pan  #{Styles::MARKERS[:bullet_sep]}  j/k/g/G #{Styles::KEYS[:arrow_up]}/#{Styles::KEYS[:arrow_down]}: scroll  #{Styles::MARKERS[:bullet_sep]}  r: reload  #{Styles::MARKERS[:bullet_sep]}  esc: close"
          else
            "esc: close"
          end
        end

        def selector_field_lines(label:, current:, choices:, selected_index:, focused:, width:)
          lines = []
          summary = "  #{label}: #{current}"
          lines << (focused ? selected_style.render(summary) : summary)
          lines.concat(wrap_rendered_segments(
                         choices.each_with_index.map do |choice, index|
                           style = index == selected_index ? selected_tab_style : tab_style
                           style.render(" #{choice} ")
                         end,
                         prefix: "    ",
                         width: width
                       ))
          lines
        end
      end
    end
  end
end
