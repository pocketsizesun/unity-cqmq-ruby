require 'bundler/setup'
require 'unity/cqmq'
require 'benchmark'

HOST_QUEUE_NAME = 'test'

@clients = [
  Unity::CQMQ::Client.new(HOST_QUEUE_NAME)
]

puts 'start loop'
started_at = Time.now.to_f
results_count = Concurrent::AtomicFixnum.new(0)
Benchmark.bm do |x|
  x.report do
    thrpool = []
    @clients.each do |client|
      thr = Thread.start(client) do |cl|
        100.times do
          req_time = Time.now.to_f
          request_data = { 'item_id' => rand(1..7), 'time' => req_time }
          begin
            # puts "send request: #{request_data}"
            resp = cl.execute('Ping', request_data)

            puts "executor REPLY: #{resp} (#{((resp['pong'] - req_time) * 1000.0).to_i}ms)"
          rescue Unity::CQMQ::Client::ResponseError => e
            puts "executor #{e.status}: #{e.data}"
          end

          results_count.increment
        end
      end

      thrpool << thr
    end
    thrpool.each(&:join)
  end
end

puts "results_count: #{results_count} in #{Time.now.to_f - started_at} seconds"
