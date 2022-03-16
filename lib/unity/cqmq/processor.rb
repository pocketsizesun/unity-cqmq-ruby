# frozen_string_literal: true

require 'connection_pool'

module Unity
  module CQMQ
    class Processor
      RECV_MESSAGE_ATTRIBUTE_NAMES = %w[reply-to request-id command].freeze
      COMMAND_NOT_FOUND_REPLY = { 'error' => 'Command not found' }.freeze

      RequestStruct = Struct.new(
        :id, :receipt_handle, :data
      )

      def self.configure(queue_name, &block)
        @queue_name = queue_name
        instance_exec(&block)
      end

      def self.options
        @options ||= {
          threads: 4,
          sqs_wait_time_seconds: 20
        }
      end

      def self.set(option_name, option_value)
        options[option_name] = option_value
      end

      def self.queue_name
        @queue_name
      end

      def self.commands
        @commands ||= {}
      end

      def self.command(name, handler = nil, &block)
        commands[name] = handler || block
      end

      def initialize(options = {})
        @sqs = Aws::SQS::Client.new
        @processor_name = options.fetch(:name) { SecureRandom.uuid }
        @queue_url = find_queue_url(self.class.queue_name, options)
        @threads_count = options.fetch(
          :threads, self.class.options.fetch(:threads)
        ).to_i
        @sqs_wait_time_seconds = options.fetch(
          :sqs_wait_time_seconds, self.class.options.fetch(:sqs_wait_time_seconds)
        ).to_i
        @thread_pool = Concurrent::FixedThreadPool.new(@threads_count)
        @json_parser = Unity::CQMQ.json_parser
        @terminate = false
      end

      def stop
        return if @terminate == true

        Unity::CQMQ.log_queue << "[#{@processor_name}] stopping processor (it can take some time...)"
        @terminate = true
      end

      def run
        Unity::CQMQ.logger&.info "[#{@processor_name}] start processor with: threads=#{@threads_count} sqs_wait_time_seconds=#{@sqs_wait_time_seconds}"

        log_queue_thread = Thread.start do
          loop do
            log = Unity::CQMQ.log_queue.pop
            Unity::CQMQ.logger&.info log
          end
        end

        # trap process signals
        Signal.trap('INT') { stop }
        Signal.trap('TERM') { stop }

        # begin infinite work loop...
        loop do
          break if @terminate == true

          Thread.handle_interrupt(Exception => :never) { do_work }
        end

        @thread_pool.shutdown
        @thread_pool.wait_for_termination

        Unity::CQMQ.logger&.info "[#{@processor_name}] processor stopped"
      end

      private

      def find_queue_url(queue_name, options = {})
        @sqs.get_queue_url(
          {
            queue_name: queue_name,
            queue_owner_aws_account_id: options.fetch(:host_queue_aws_account_id, nil)
          }.compact
        ).queue_url
      end

      def do_work
        messages = receive_messages
        if Unity::CQMQ.logger.level == Logger::DEBUG
          Unity::CQMQ.logger&.debug "receive messages count: #{messages.length}"
        end

        messages.each do |message|
          @thread_pool.post(message) do |msg|
            Thread.handle_interrupt(Exception => :never) do
              process_message(msg)
            end
          end
        end
      end

      def receive_messages
        @sqs.receive_message(
          queue_url: @queue_url,
          message_attribute_names: RECV_MESSAGE_ATTRIBUTE_NAMES,
          max_number_of_messages: 10,
          visibility_timeout: 30,
          wait_time_seconds: @sqs_wait_time_seconds
        ).messages
      rescue StandardError => e
        Unity::CQMQ.logger&.error(
          "[#{@processor_name}] receive message uncaught exception: #{e.message} (#{e.class}"
        )
        []
      end

      def reply_to(queue_url, request_id, status, data)
        retries_count = 0

        begin
          message_body = @json_parser.dump(data.respond_to?(:as_json) ? data.as_json : data)
          thread_sqs_client.send_message(
            queue_url: queue_url,
            message_body: message_body,
            message_attributes: {
              'request-id' => { string_value: request_id, data_type: 'String' },
              'status' => { string_value: status, data_type: 'String' }
            }
          )
        rescue Aws::SQS::Errors::NonExistentQueue
          retries_count += 1
          if retries_count < 5
            sleep 1
            retry
          end
        end
      end

      def process_message(msg)
        request_data = @json_parser.load(msg.body)
        request_id = msg.message_attributes['request-id'].string_value
        reply_to_queue_url = msg.message_attributes['reply-to'].string_value

        command_name = msg.message_attributes.fetch('command', nil)&.string_value
        if command_name.nil? || !self.class.commands.key?(command_name)
          reply_to(
            reply_to_queue_url,
            request_id,
            Unity::CQMQ::STATUS_COMMAND_NOT_FOUND,
            COMMAND_NOT_FOUND_REPLY
          )
        else
          begin
            reply_data = execute_command(command_name, request_data)
            reply_to(
              reply_to_queue_url,
              request_id,
              Unity::CQMQ::STATUS_OK,
              reply_data
            )
          rescue Unity::CQMQ::CommandError => e
            reply_to(
              reply_to_queue_url,
              request_id,
              Unity::CQMQ::STATUS_ERROR,
              e.as_reply_data
            )
          rescue StandardError => e
            Unity::CQMQ.logger&.fatal(
              "[#{@processor_name}] process message uncaught exception: #{e.message} (#{e.class})"
            )
            reply_to(
              reply_to_queue_url,
              request_id,
              Unity::CQMQ::STATUS_SERVICE_ERROR,
              { 'error' => e.message }
            )
          end
        end

        thread_sqs_client.delete_message(
          queue_url: @queue_url,
          receipt_handle: msg.receipt_handle
        )
      end

      def execute_command(command_name, request_data)
        command_handler = self.class.commands[command_name]

        if command_handler.is_a?(Symbol)
          __send__(command_handler, request_data)
        else
          command_handler.call(request_data)
        end
      end

      def thread_sqs_client
        Thread.current[:cqmq_sqs] ||= Aws::SQS::Client.new
      end
    end
  end
end
