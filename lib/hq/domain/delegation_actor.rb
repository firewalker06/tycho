# frozen_string_literal: true

module HQ
  class DelegationActor
    Actor = Struct.new(:type, :agent_key, keyword_init: true) do
      def user? = type == "user"
      def parent? = type == "parent"
    end

    def self.user_actor
      Actor.new(type: "user")
    end

    def self.parent_actor(agent_key)
      key = agent_key.to_s.strip
      raise ArgumentError, "Missing parent agent key" if key.empty?

      Actor.new(type: "parent", agent_key: key)
    end
  end
end
