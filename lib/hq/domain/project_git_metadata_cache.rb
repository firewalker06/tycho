# frozen_string_literal: true

module HQ
  # Shared git metadata for configured projects. Request-scoped services apply
  # cached values without running git; only refresh runs git, from the server's timer.
  class ProjectGitMetadataCache
    def initialize
      @entries = {}
      @mutex = Mutex.new
    end

    def apply(project)
      metadata = @mutex.synchronize { @entries[cache_key(project)] }
      project.apply_git_metadata(metadata) if metadata
      project
    end

    # Merges the fields that were read successfully, so each field keeps its last valid value.
    def refresh(project)
      metadata = project.refresh_metadata!
      return project if metadata.empty?

      @mutex.synchronize do
        key = cache_key(project)
        @entries[key] = (@entries[key] || {}).merge(metadata).freeze
      end
      project
    end

    # True when every git field has a cached value, so reload does not need to refresh the project.
    def known?(project)
      metadata = @mutex.synchronize { @entries[cache_key(project)] }
      !metadata.nil? && (Project::GIT_FIELDS - metadata.keys).empty?
    end

    private

    def cache_key(project)
      [project.key, project.path]
    end
  end
end
