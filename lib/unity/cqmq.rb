# frozen_string_literal: true

require 'json'
require 'securerandom'
require 'aws-sdk-sqs'
require 'concurrent-ruby'

require_relative 'cqmq/version'
require 'unity/cqmq/error'
require 'unity/cqmq/command_error'
require 'unity/cqmq/client'

module Unity
  module CQMQ
    CLIENT_QUEUE_HEARTBEAT_TAG_NAME = 'unity-cqmq:HeartbeatAt'
    CLIENT_QUEUE_NAME_PREFIX = 'cqmq-cl'

    STATUS_COMMAND_NOT_FOUND = 'COMMAND_NOT_FOUND'
    STATUS_ERROR             = 'ERROR'
    STATUS_SERVICE_ERROR     = 'SERVICE_ERROR'
    STATUS_OK                = 'OK'

    module_function

    def json_parser
      @json_parser ||= \
        if defined?(Oj)
          ::Oj
        else
          ::JSON
        end
    end

    def json_parser=(arg)
      @json_parser = arg
    end

    def log_queue
      @log_queue ||= Queue.new
    end

    def logger
      @logger ||= Logger.new($stdout)
    end

    def logger=(logger)
      @logger = logger
    end
  end
end
