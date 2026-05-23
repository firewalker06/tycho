# frozen_string_literal: true

require_relative "styles"

module HQ
  module UI
    module Rendering
      # Resolves what a project's status cell should show right now.
      #
      # The same decision tree (active action > recent result > steady state)
      # drove four near-duplicate methods in StatusHelpers. Callers build a
      # badge once and ask for the plain text, the spinner hint, or the style
      # key separately.
      class ProjectStatusBadge
        SUCCESS_RESULT_TTL = 15 # seconds
        FAILED_RESULT_TTL = 300 # seconds

        Kind = Module.new
        ACTIVE = :active
        RESULT = :result
        STEADY = :steady

        attr_reader :kind, :text, :style_key, :spinner, :action_label

        def self.for(project, action:, result:, now: Time.now, steady: :app)
          return active_badge(action) if action
          return result_badge(project, result) if result_active?(result, now:)

          steady == :health ? steady_health_badge(project) : steady_badge(project)
        end

        def self.result_active?(result, now: Time.now)
          return false unless result

          ttl = result[:success] ? SUCCESS_RESULT_TTL : FAILED_RESULT_TTL
          now - result[:at] < ttl
        end

        def self.steady_health_badge(project)
          text = health_text(project)
          text += " #{project.response_time}ms" if project.response_time
          new(kind: STEADY, text: text, style_key: health_style_key(project))
        end

        def self.health_text(project)
          case project.health_status
          when "healthy" then "#{Styles::MARKERS[:dot]} up"
          when "maintenance" then "#{Styles::MARKERS[:triangle]} maint"
          when "pending" then "#{Styles::MARKERS[:circle]} ..."
          when "not checked" then "#{Styles::MARKERS[:circle]} n/a"
          else "#{Styles::MARKERS[:dot]} down"
          end
        end

        def self.health_style_key(project)
          case project.health_status
          when "healthy" then :healthy
          when "maintenance" then :maintenance
          when "pending" then :pending
          when "not checked" then :dim
          else :fail
          end
        end

        def self.active_badge(action)
          new(kind: ACTIVE, text: action.label, style_key: :dim, spinner: true, action_label: action.label)
        end

        def self.result_badge(project, result)
          success = result[:success]
          app_healthy = project.health_status == "healthy" || project.app_status == "running"
          mark = success ? Styles::MARKERS[:check] : app_healthy ? Styles::MARKERS[:bang] : Styles::MARKERS[:cross]
          new(
            kind: RESULT,
            text: "#{mark} #{result[:action]}",
            style_key: success ? :success : app_healthy ? :warning : :fail,
            spinner: false
          )
        end

        def self.steady_badge(project)
          case project.app_status
          when "running" then new(kind: STEADY, text: "#{Styles::MARKERS[:dot]} running", style_key: :healthy)
          when "maintenance" then new(kind: STEADY, text: "#{Styles::MARKERS[:triangle]} maintenance", style_key: :maintenance)
          when "pending" then new(kind: STEADY, text: "#{Styles::MARKERS[:circle]} ...", style_key: :pending)
          else new(kind: STEADY, text: "#{Styles::MARKERS[:dot]} #{project.app_status}", style_key: :fail)
          end
        end

        def initialize(kind:, text:, style_key:, spinner: false, action_label: nil)
          @kind = kind
          @text = text
          @style_key = style_key
          @spinner = spinner
          @action_label = action_label
        end

        def spinner?
          @spinner
        end
      end
    end
  end
end
