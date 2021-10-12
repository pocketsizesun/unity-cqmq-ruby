# frozen_string_literal: true

module Unity
  module CQMQ
    class Client
      RECV_MESSAGE_ATTRIBUTE_NAMES = %w[request-id status].freeze

      Error = Class.new(Unity::CQMQ::Error)
      ResponseStruct = Struct.new(:status, :data)
      ResponseError = Class.new(Error) do
        attr_reader :status, :data

        def initialize(status, data)
          @status = status
          @data = data
          super("response error: #{status}")
        end
      end
      TimeoutError = Class.new(Error)

      # @param [String] host_queue_name
      # @option options [String] host_queue_aws_account_id
      def initialize(host_queue_name, options = {})
        @sqs = Aws::SQS::Client.new
        @uuid = SecureRandom.uuid
        @host_queue_url = find_host_queue_url(host_queue_name, options)
        @compression = options.fetch(:compression, nil)
        @client_queue_name = "#{Unity::CQMQ::CLIENT_QUEUE_NAME_PREFIX}-#{SecureRandom.uuid}"
        @client_queue = create_client_queue
        @client_queue_url = find_client_queue_url
        @max_retries_count = options.fetch(:max_retries_count, 3)
        @mutex = Mutex.new
        @heartbeat_thread = spawn_heartbeat_thread
        @json_parser = Unity::CQMQ.json_parser
        @closed = false
        Kernel.at_exit { close } if options.fetch(:at_exit_close, true) == true
      end

      def execute(command_name, data, timeout: 60)
        @mutex.synchronize do
          request_uuid = SecureRandom.uuid
          @sqs.send_message(
            queue_url: @host_queue_url,
            message_body: @json_parser.dump(data),
            message_attributes: {
              'command' => { string_value: command_name, data_type: 'String' },
              'request-id' => { string_value: request_uuid, data_type: 'String' },
              'reply-to' => { string_value: @client_queue_url, data_type: 'String' }
            }
          )

          wait_for_reply(request_uuid, timeout: timeout)
        end
      end

      def close
        if @closed == false
          begin
            @sqs.delete_queue(
              queue_url: @client_queue_url
            )
          rescue Aws::SQS::Errors::NonExistentQueue
            # do nothing
          end

          @closed = true
          puts "close client"
        end

        true
      end

      private

      def create_client_queue
        @sqs.create_queue(
          queue_name: @client_queue_name,
          attributes: {
            'MessageRetentionPeriod' => '600',
            'ReceiveMessageWaitTimeSeconds' => '20'
          },
          tags: {
            Unity::CQMQ::CLIENT_QUEUE_HEARTBEAT_TAG_NAME => Time.now.to_i.to_s
          }
        )
      end

      def find_client_queue_url
        retries_count = 0
        begin
          @sqs.get_queue_url(queue_name: @client_queue_name).queue_url
        rescue Aws::SQS::Errors::NonExistentQueue
          retries_count += 1
          if retries_count <= 10
            sleep 2
            retry
          end

          raise Unity::CQMQ::Error, 'Unable to get client queue URL'
        end
      end

      def spawn_heartbeat_thread
        Thread.start do
          loop do
            begin
              @sqs.tag_queue(
                queue_url: @client_queue_url,
                tags: {
                  Unity::CQMQ::CLIENT_QUEUE_HEARTBEAT_TAG_NAME => Time.now.to_i.to_s
                }
              )

              sleep rand(60..120)
            rescue StandardError => e
              # do nothing
              Unity::CQMQ.logger&.error(
                "[processor-heartbeat-thread] uncaught exception: #{e.messasge} (#{e.class})"
              )
              sleep 5
            end
          end
        end
      end

      def find_host_queue_url(queue_name, options = {})
        @sqs.get_queue_url(
          {
            queue_name: queue_name,
            queue_owner_aws_account_id: options.fetch(:host_queue_aws_account_id, nil)
          }.compact
        ).queue_url
      end

      def wait_for_reply(request_uuid, timeout: 60)
        started_at = Time.now.to_i

        loop do
          raise TimeoutError if started_at + timeout < Time.now.to_i

          result = @sqs.receive_message(
            queue_url: @client_queue_url,
            message_attribute_names: RECV_MESSAGE_ATTRIBUTE_NAMES,
            max_number_of_messages: 1,
            visibility_timeout: 30,
            wait_time_seconds: 20
          )
          next if result.messages.length == 0

          message = result.messages.first

          @sqs.delete_message(
            queue_url: @client_queue_url,
            receipt_handle: message.receipt_handle
          )
          next unless request_uuid == message.message_attributes['request-id'].string_value

          resp_status = message.message_attributes['status'].string_value
          unless resp_status == Unity::CQMQ::STATUS_OK
            raise ResponseError.new(
              resp_status, @json_parser.load(message.body)
            )
          end

          return @json_parser.load(message.body)
        end
      end
    end
  end
end
