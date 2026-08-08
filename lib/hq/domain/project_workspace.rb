# frozen_string_literal: true

module HQ
  class ProjectWorkspace
    DEFAULT_PAGE_SIZE = 100
    MAX_PAGE_SIZE = 200
    MAX_DIRECTORY_ENTRIES = 5_000
    MAX_NAME_BYTES = 1_024
    MAX_PREVIEW_BYTES = 256 * 1024
    EXCLUDED_DIRECTORIES = %w[
      .bundle .cache .git .hg .svn .terraform .yardoc
      build coverage dist log logs node_modules pkg tmp vendor
    ].freeze
    SENSITIVE_NAMES = %w[
      .aws .env .envrc .gnupg .netrc .npmrc .pypirc .ssh credentials credentials.json
      id_dsa id_ecdsa id_ed25519 id_rsa known_hosts
    ].freeze
    SENSITIVE_SUFFIXES = %w[.key .p12 .pfx .pem].freeze
    PRIVATE_KEY_MARKER = /-----BEGIN (?:[A-Z0-9 ]+ )?PRIVATE KEY-----/.freeze
    SECRET_VALUE_PATTERNS = [
      /\b(?:AKIA|ASIA)[A-Z0-9]{16}\b/,
      /\bAIza[0-9A-Za-z_-]{30,}\b/,
      /\bgh[pousr]_[A-Za-z0-9_]{20,}\b/,
      /\b(?:glpat|pypi)-[A-Za-z0-9_-]{16,}\b/,
      /\b(?:npm|hf)_[A-Za-z0-9_-]{16,}\b/,
      /\bsk-[A-Za-z0-9_-]{20,}\b/,
      /\bsk_live_[A-Za-z0-9]{16,}\b/,
      /\bxox[baprs]-[A-Za-z0-9-]{10,}\b/,
      /\b(?:postgres(?:ql)?|mysql|mongodb(?:\+srv)?|redis|rediss|amqp|amqps):\/\/[^\s"']+/i,
      /(?:\A|[\r\n{,])\s*["']?(?:api[_-]?key|access[_-]?token|auth[_-]?token|client[_-]?secret|database[_-]?url|db[_-]?url|password|private[_-]?key|secret|secret[_-]?key(?:[_-]?base)?|signing[_-]?key|token)["']?\s*:\s*(?:"[^"\r\n]{8,}"|'[^'\r\n]{8,}'|(?!example\b|placeholder\b|redacted\b|changeme\b|null\b|nil\b|false\b|true\b)[A-Za-z0-9_+\/=.-]{8,}(?=\s*(?:[#;,}]|\z|[\r\n])))/i,
      /(?:\A|[\r\n])\s*(?:(?:const|let|var)\s+)?["']?(?:api[_-]?key|access[_-]?token|auth[_-]?token|client[_-]?secret|database[_-]?url|db[_-]?url|password|private[_-]?key|secret|secret[_-]?key(?:[_-]?base)?|signing[_-]?key|token)["']?\s*=\s*(?:"[^"\r\n]{8,}"|'[^'\r\n]{8,}')/i,
      /(?:\A|[\r\n])\s*(?:export\s+)?(?:API_KEY|ACCESS_TOKEN|AUTH_TOKEN|CLIENT_SECRET|DATABASE_URL|DB_URL|PASSWORD|PRIVATE_KEY|SECRET|SECRET_KEY(?:_BASE)?|SIGNING_KEY|TOKEN)\s*=\s*(?!example\b|placeholder\b|redacted\b|changeme\b|null\b|nil\b|false\b|true\b)[A-Za-z0-9_+\/=.-]{8,}(?=\s*(?:[#;]|\z|[\r\n]))/
    ].freeze

    class Error < StandardError
      attr_reader :code, :status

      def initialize(code, message, status:)
        super(message)
        @code = code
        @status = status
      end
    end

    def initialize(root)
      @configured_root = root.to_s
    end

    def list(path: "", offset: 0, limit: DEFAULT_PAGE_SIZE)
      root = canonical_root!
      relative = normalize_relative_path(path)
      directory = resolve!(root, relative, kind: :directory)
      entries = directory_entries(root, directory, relative)
      page_offset = bounded_offset(offset)
      page_limit = bounded_limit(limit)
      page = entries.slice(page_offset, page_limit) || []

      {
        path: relative,
        parent: parent_path(relative),
        entries: page,
        offset: page_offset,
        limit: page_limit,
        total: entries.length,
        next_offset: page_offset + page.length < entries.length ? page_offset + page.length : nil,
        truncated: false
      }
    rescue Errno::EACCES, Errno::EPERM
      raise Error.new("permission_denied", "Workspace directory is not readable", status: 403)
    rescue Errno::ENOENT, Errno::ENOTDIR
      raise Error.new("not_found", "Workspace path is no longer available", status: 404)
    end

    def preview(path:)
      root = canonical_root!
      relative = normalize_relative_path(path)
      raise invalid_path if relative.empty?

      file = resolve!(root, relative, kind: :file)
      stat = File.stat(file)
      raise too_large if stat.size > MAX_PREVIEW_BYTES

      bytes = File.binread(file, MAX_PREVIEW_BYTES + 1)
      raise too_large if bytes.bytesize > MAX_PREVIEW_BYTES
      raise Error.new("binary", "Binary files cannot be previewed", status: 415) if binary?(bytes)

      content = bytes.dup.force_encoding(Encoding::UTF_8)
      content = content.scrub("\uFFFD") unless content.valid_encoding?
      if sensitive_content?(content)
        raise Error.new("sensitive", "Sensitive files cannot be previewed", status: 403)
      end

      {
        path: relative,
        name: File.basename(relative),
        size_bytes: stat.size,
        content: content,
        truncated: false
      }
    rescue Errno::EACCES, Errno::EPERM
      raise Error.new("permission_denied", "Workspace file is not readable", status: 403)
    rescue Errno::ENOENT, Errno::ENOTDIR
      raise Error.new("not_found", "Workspace file is no longer available", status: 404)
    end

    private

    def canonical_root!
      raise unavailable_root unless File.directory?(@configured_root)

      File.realpath(@configured_root)
    rescue Errno::ENOENT, Errno::EACCES, Errno::EPERM
      raise unavailable_root
    end

    def normalize_relative_path(value)
      raw = value.to_s
      raise invalid_path if raw.include?("\0") || !raw.valid_encoding?
      raise invalid_path if raw.start_with?("/", "\\") || raw.match?(/\A[A-Za-z]:[\\\/]/)
      raise invalid_path if raw.match?(/%[0-9a-f]{2}/i)

      clean = raw.tr("\\", "/").split("/", -1)
      raise invalid_path if clean.any? { |part| part == ".." }

      clean.reject { |part| part.empty? || part == "." }.join("/")
    end

    def resolve!(root, relative, kind:)
      candidate = relative.empty? ? root : File.join(root, relative)
      resolved = File.realpath(candidate)
      raise invalid_path unless inside_root?(root, resolved)
      raise Error.new("not_found", "Workspace path is no longer available", status: 404) unless public_path?(relative)

      valid = kind == :directory ? File.directory?(resolved) : File.file?(resolved)
      raise Error.new("wrong_type", "Workspace path has the wrong type", status: 409) unless valid

      resolved
    rescue Errno::ENOENT, Errno::ENOTDIR
      raise Error.new("not_found", "Workspace path is no longer available", status: 404)
    rescue Errno::ELOOP
      raise invalid_path
    end

    def directory_entries(root, directory, relative)
      names = []
      Dir.each_child(directory) do |name|
        names << name
        if names.length > MAX_DIRECTORY_ENTRIES
          raise Error.new("directory_too_large", "Directory has too many entries to browse", status: 413)
        end
      end

      entries = names.filter_map do |name|
        next unless safe_name?(name)

        child_relative = relative.empty? ? name : "#{relative}/#{name}"
        next unless public_path?(child_relative)

        entry_payload(root, directory, child_relative, name)
      end
      entries.sort_by { |entry| [entry[:kind] == "directory" ? 0 : 1, sort_name(entry[:name]), entry[:name].b] }
    end

    def entry_payload(root, directory, relative, name)
      candidate = File.join(directory, name)
      resolved = File.realpath(candidate)
      return nil unless inside_root?(root, resolved)

      stat = File.stat(resolved)
      kind = stat.directory? ? "directory" : stat.file? ? "file" : nil
      return nil unless kind

      {
        name: name.encode(Encoding::UTF_8),
        path: relative,
        kind: kind,
        size_bytes: kind == "file" ? stat.size : nil,
        symlink: File.symlink?(candidate)
      }.compact
    rescue Errno::ENOENT, Errno::EACCES, Errno::EPERM, Errno::ELOOP, EncodingError
      nil
    end

    def public_path?(relative)
      parts = relative.split("/")
      return false if parts.any? { |part| excluded_directory?(part) }
      return false if parts.any? { |part| sensitive_name?(part) }

      true
    end

    def excluded_directory?(name)
      EXCLUDED_DIRECTORIES.include?(name.downcase) || name.downcase.end_with?(".cache")
    end

    def sensitive_name?(name)
      normalized = name.downcase
      return false if %w[.env.example .env.sample credentials.example credentials.sample].include?(normalized)
      return true if SENSITIVE_NAMES.include?(normalized)
      return true if normalized.start_with?(".env.")
      return true if normalized.include?("credential") || normalized.include?("private-key") || normalized.include?("private_key")
      return true if normalized.match?(/\A(?:passwords?|secrets?|tokens?)(?:\.(?:conf|ini|json|toml|txt|ya?ml))?\z/)

      SENSITIVE_SUFFIXES.any? { |suffix| normalized.end_with?(suffix) }
    end

    def safe_name?(name)
      name.valid_encoding? && name.bytesize <= MAX_NAME_BYTES && ["\0", "/", "\\"].none? { |char| name.include?(char) }
    end

    def sort_name(name)
      name.unicode_normalize(:nfc).downcase
    rescue EncodingError
      name
    end

    def inside_root?(root, path)
      path == root || path.start_with?("#{root}#{File::SEPARATOR}")
    end

    def binary?(bytes)
      return true if bytes.include?("\0")

      text = bytes.dup.force_encoding(Encoding::UTF_8)
      return false if text.valid_encoding?

      valid_bytes = text.scrub("").bytesize
      bytes.bytesize.positive? && valid_bytes < bytes.bytesize * 0.85
    end

    def sensitive_content?(content)
      content.match?(PRIVATE_KEY_MARKER) || SECRET_VALUE_PATTERNS.any? { |pattern| content.match?(pattern) }
    end

    def parent_path(relative)
      return nil if relative.empty?

      parent = File.dirname(relative)
      parent == "." ? "" : parent
    end

    def bounded_offset(value)
      offset = Integer(value || 0)
      raise Error.new("invalid_pagination", "Workspace offset is invalid", status: 400) if offset.negative?

      offset
    rescue ArgumentError, TypeError
      raise Error.new("invalid_pagination", "Workspace offset is invalid", status: 400)
    end

    def bounded_limit(value)
      limit = Integer(value || DEFAULT_PAGE_SIZE)
      raise Error.new("invalid_pagination", "Workspace limit is invalid", status: 400) unless limit.between?(1, MAX_PAGE_SIZE)

      limit
    rescue ArgumentError, TypeError
      raise Error.new("invalid_pagination", "Workspace limit is invalid", status: 400)
    end

    def invalid_path
      Error.new("invalid_path", "Workspace path is invalid", status: 400)
    end

    def unavailable_root
      Error.new("workspace_unavailable", "Project workspace is unavailable", status: 404)
    end

    def too_large
      Error.new("too_large", "File is too large to preview", status: 413)
    end
  end
end
