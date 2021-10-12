# frozen_string_literal: true

puts "using JSON parser: #{Unity::CQMQ.json_parser.name}"
Unity::CQMQ::Processor.configure('test') do
  # set :sqs_wait_time_seconds, 5

  command 'Ping' do |args|
    item_id = args.fetch('item_id').to_i
    raise "argument error: #{item_id}" if item_id == 7

    { 'item_id' => item_id, 'pong' => Time.now.to_f }
  rescue KeyError => e
    raise Unity::CQMQ::CommandError.new(
      "Missing required parameter '#{e.key}'",
      'parameter_name' => e.key
    )
  end
end
