# frozen_string_literal: true

module HQ
  module UsageMetrics
    module Values
      module_function

      def numeric(value)
        number = Float(value)
        number if number.finite? && number >= 0
      rescue ArgumentError, TypeError
        nil
      end

      def present(value)
        text = value.to_s.strip
        text unless text.empty?
      end

      def stringify(value)
        case value
        when Hash then value.each_with_object({}) { |(key, entry), result| result[key.to_s] = stringify(entry) }
        when Array then value.map { |entry| stringify(entry) }
        else value
        end
      end
    end
  end
end
