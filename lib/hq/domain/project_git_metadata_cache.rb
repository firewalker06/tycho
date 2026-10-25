# frozen_string_literal: true

module HQ
  # Shared git metadata for configured projects. Request-scoped services apply
  # cached values without running git; only refresh runs git, from a background timer.
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

    # A failed read returns nil from Project#refresh_metadata!, so the last good entry stays.
    def refresh(project)
      metadata = project.refresh_metadata!
      @mutex.synchronize { @entries[cache_key(project)] = metadata.freeze } if metadata
      project
    end

    private

    def cache_key(project)
      [project.key, project.path]
    end
  end
end
