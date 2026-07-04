# frozen_string_literal: true

require_relative "project_status_badge"

module HQ
  module UI
    module Rendering
      module StatusHelpers
        private

        def project_status_badge(project)
          ProjectStatusBadge.for(project)
        end

        def style_for_badge_key(key)
          case key
          when :healthy then healthy_style
          when :maintenance then maintenance_style
          when :pending then pending_style
          when :warning then warning_style.bold(true)
          when :success then success_style
          when :fail then fail_style
          when :dim then dim_style
          else dim_style
          end
        end

        def render_badge_text(badge)
          badge.text
        end

        def plain_status_text_for(project)
          render_badge_text(project_status_badge(project))
        end

        def status_text_for(project)
          project_status_style_for(project).render(plain_status_text_for(project))
        end

        def project_status_style_for(project)
          style_for_badge_key(project_status_badge(project).style_key)
        end

        def plain_status_text_for_row(project)
          render_badge_text(project_status_badge(project))
        end

        def project_status_styled_cell(project, width)
          badge = project_status_badge(project)
          text = render_badge_text(badge)
          pad_visible(style_for_badge_key(badge.style_key).render(text), width)
        end

        PROJECT_STATUS_META = {
          healthy: { label: "configured", icon: Styles::STATUS_ICONS[:healthy], style: :healthy },
          pending: { label: "pending", icon: Styles::STATUS_ICONS[:pending], style: :pending },
          dim: { label: "workspace", icon: Styles::STATUS_ICONS[:dim], style: :dim }
        }.freeze

        PROJECT_STATUS_LEGEND_KEYS = %i[healthy pending dim].freeze

        def styled_project_status_icon(project, spinner: false)
          badge = project_status_badge(project)
          glyph = spinner && badge.spinner? ? @spinner.view : project_status_icon(badge.style_key)
          project_status_meta_style(badge.style_key).render(glyph)
        end

        def project_status_icon(style_key)
          (PROJECT_STATUS_META[style_key] || PROJECT_STATUS_META[:dim])[:icon]
        end

        def project_status_meta_style(style_key)
          style_for_badge_key((PROJECT_STATUS_META[style_key] || PROJECT_STATUS_META[:dim])[:style])
        end

        def project_status_legend_block(_width)
          entries = PROJECT_STATUS_LEGEND_KEYS.map do |style_key|
            meta = PROJECT_STATUS_META[style_key]
            "#{project_status_meta_style(style_key).render(meta[:icon])} #{dim_style.render(meta[:label])}"
          end
          [dim_style.render("Status:"), *entries].join("\n")
        end

        AGENT_STATUS_META = {
          "running" => { label: "running", style: :healthy },
          "awaiting-input" => { label: "needs input", style: :warning },
          "input_required" => { label: "needs input", style: :warning },
          "completed" => { label: "done", style: :success },
          "succeeded" => { label: "done", style: :success },
          "success" => { label: "done", style: :success },
          "error" => { label: "error", style: :fail },
          "failed" => { label: "error", style: :fail },
          "stopped" => { label: "stopped", style: :maintenance },
          "partial" => { label: "partial", style: :warning },
          "blocked" => { label: "blocked", style: :fail },
          "idle" => { label: "idle", style: :dim }
        }.freeze

        AGENT_STATUS_LEGEND_KEYS = %w[running awaiting-input completed error idle].freeze

        def agent_status_icon(status)
          case status.to_s
          when "running" then Styles::STATUS_ICONS[:running]
          when "succeeded", "success", "completed" then Styles::STATUS_ICONS[:succeeded]
          when "failed", "error" then Styles::STATUS_ICONS[:failed]
          when "stopped" then Styles::STATUS_ICONS[:stopped]
          when "awaiting-input", "input_required" then Styles::STATUS_ICONS[:awaiting_input]
          when "partial" then Styles::STATUS_ICONS[:partial]
          when "blocked" then Styles::STATUS_ICONS[:blocked]
          else Styles::STATUS_ICONS[:unknown]
          end
        end

        def agent_status_style(status)
          meta = AGENT_STATUS_META[status.to_s] || { style: :dim }
          case meta[:style]
          when :healthy then healthy_style
          when :warning then warning_style.bold(true)
          when :success then success_style
          when :fail then fail_style
          when :maintenance then maintenance_style
          else dim_style
          end
        end

        def agent_status_label(status)
          (AGENT_STATUS_META[status.to_s] || { label: status.to_s })[:label]
        end

        def styled_agent_status_icon(status, spinner: false)
          glyph = spinner && status.to_s == "running" ? @spinner.view : agent_status_icon(status)
          agent_status_style(status).render(glyph)
        end

        def styled_agent_status(status, spinner: false)
          agent_status_style(status).render("#{agent_status_icon(status)} #{agent_status_label(status)}")
        end

        def agent_status_legend_block(_width)
          entries = AGENT_STATUS_LEGEND_KEYS.map do |status|
            "#{styled_agent_status_icon(status)} #{dim_style.render(agent_status_label(status))}"
          end
          [dim_style.render("Status:"), *entries].join("\n")
        end

        SCHEDULE_STATUS_META = {
          "scheduled" => { label: "scheduled", icon: Styles::STATUS_ICONS[:pending], style: :healthy },
          "paused" => { label: "paused", icon: Styles::STATUS_ICONS[:stopped], style: :maintenance },
          "stopped" => { label: "stopped", icon: Styles::STATUS_ICONS[:failed], style: :fail }
        }.freeze

        SCHEDULE_STATUS_LEGEND_KEYS = %w[scheduled paused stopped].freeze

        def schedule_status_key(schedule)
          schedule[:status].to_s.empty? ? "scheduled" : schedule[:status].to_s
        end

        def schedule_status_meta(schedule_or_key)
          key = schedule_or_key.is_a?(Hash) ? schedule_status_key(schedule_or_key) : schedule_or_key.to_s
          SCHEDULE_STATUS_META[key] || SCHEDULE_STATUS_META["scheduled"]
        end

        def schedule_status_style(schedule_or_key)
          meta = schedule_status_meta(schedule_or_key)
          case meta[:style]
          when :healthy then healthy_style
          when :warning then warning_style.bold(true)
          when :success then success_style
          when :fail then fail_style
          when :maintenance then maintenance_style
          else dim_style
          end
        end

        def styled_schedule_status_icon(schedule)
          meta = schedule_status_meta(schedule)
          schedule_status_style(schedule).render(meta[:icon])
        end

        def schedule_status_legend_block(_width)
          entries = SCHEDULE_STATUS_LEGEND_KEYS.map do |status|
            meta = schedule_status_meta(status)
            "#{schedule_status_style(status).render(meta[:icon])} #{dim_style.render(meta[:label])}"
          end
          [dim_style.render("Status:"), *entries].join("\n")
        end

        def status_style_for(status)
          case status
          when "running" then healthy_style
          when "succeeded" then success_style
          when "stopped" then maintenance_style
          when "failed" then fail_style
          else dim_style
          end
        end

        def result_style_for(result)
          case result
          when "in progress" then healthy_style
          when "success" then success_style
          when "stopped" then maintenance_style
          when "failed" then fail_style
          else dim_style
          end
        end

        def project_git_cell(project)
          commit = (project.commit_hash || "n/a")[0, 7]
          dirty = project.dirty_files.positive? ? "#{project.dirty_files} dirty" : "clean"
          branch = project.branch || "n/a"
          "#{commit} #{dirty} #{branch}"
        end

        def project_git_styled_cell(project, width)
          commit = (project.commit_hash || "n/a")[0, 7]
          dirty = project.dirty_files.positive? ? "#{project.dirty_files} dirty" : "clean"
          branch = project.branch || "n/a"
          plain = "#{commit} #{dirty} #{branch}"
          truncated = truncate(plain, width)
          dirty_styled = project.dirty_files.positive? ? warning_style.render(dirty) : success_style.render(dirty)
          styled = truncated.sub(dirty, dirty_styled)
          pad_visible(styled, width)
        end

      end
    end
  end
end
