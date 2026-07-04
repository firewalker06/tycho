# frozen_string_literal: true

module HQ
  module UI
    module Rendering
      module Layout
        private

        def table_content_width
          [panel_total_width, 20].max
        end

        def table_rule_line
          "#{horizontal_margin_prefix}#{Styles::BOX[:h] * [table_content_width, 20].max} "
        end

        def horizontal_margin
          1
        end

        def horizontal_margin_prefix
          " " * horizontal_margin
        end

        def table_header_prefix
          "#{horizontal_margin_prefix}  "
        end

        def panel_total_width
          [main_column_width - 4, 24].max
        end

        def detail_content_width
          # panel_total_width is fed to Lipgloss .width(), which yields a
          # container of panel_total_width + 2 terminal columns (border).
          # Interior = panel_total_width; minus padding(0, 1) = -2 → content.
          [panel_total_width - 2, 20].max
        end

        def detail_overlay_width
          [@window_width - 6, 40].max
        end

        def detail_overlay_height
          [@window_height - 6, 10].max
        end

        def footer_content_width
          [@window_width - 2, 20].max
        end

        def split_gap_width
          2
        end

        def body_total_width
          [@window_width - 2, 40].max
        end

        def list_sidebar_total_width
          available = body_total_width
          proposed = [[(available * 0.28).floor, 20].max, 30].min
          [proposed, available - 32].min
        end

        def sidebar_total_width
          return list_sidebar_total_width if sidebar_visible?

          0
        end

        def main_column_width
          return body_total_width unless sidebar_visible?

          [body_total_width - sidebar_total_width - split_gap_width, 32].max
        end

        def sidebar_content_width
          [panel_total_width - 4, 20].max
        end

        def sidebar_component_width
          [sidebar_content_width, 20].max
        end

        def sidebar_component_body_height
          [[@window_height - 14, 8].max, 30].min
        end

        def sidebar_text_height
          [@window_height - 12, 6].max
        end

        def list_content_width
          [list_sidebar_total_width - 4, 12].max
        end

        def list_body_height
          [@window_height - 8, 6].max
        end

        def project_table_widths
          total = table_content_width
          fixed = { agents: 3, status: 14 }
          remaining = [total - fixed.values.sum - 3, 30].max
          project = [(remaining * 0.25).floor, 12].max
          git = [remaining - project, 16].max
          { project: project, git: git, status: fixed[:status], agents: fixed[:agents] }
        end

        def agent_table_widths
          total = table_content_width
          fixed = { status: 10, result: 20, updated: 7 }
          remaining = [total - fixed.values.sum - 5, 24].max
          project = [(remaining * 0.2).floor, 10].max
          agent = [(remaining * 0.28).floor, 12].max
          workspace = [remaining - project - agent, 12].max
          { status: fixed[:status], project: project, agent: agent, result: fixed[:result], updated: fixed[:updated],
            workspace: workspace }
        end

        def bubble_content_width
          [chat_content_width - 2, 18].max
        end

        def chat_content_width
          [@agent_chat_form&.viewport&.width || [@window_width - 4, 20].max, 20].max
        end

        def chat_divider_width
          [panel_total_width - 2, 12].max
        end
      end
    end
  end
end
