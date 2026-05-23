# frozen_string_literal: true

module HQ
  module ProcessLiveness
    module_function

    def alive?(pid)
      return false unless pid

      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end
  end
end
