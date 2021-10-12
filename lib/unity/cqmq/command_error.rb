# frozen_string_literal: true

module Unity
  module CQMQ
    class CommandError < Error
      attr_reader :data

      def initialize(message, data = {})
        @data = data
        super(message)
      end

      def as_reply_data
        { 'error' => message, 'data' => @data }
      end
    end
  end
end
