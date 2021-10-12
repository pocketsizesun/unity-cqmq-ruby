# frozen_string_literal: true

module Unity
  module CQMQ
    class Launcher
      WorkerEntry = Struct.new(:pid, :index, :pipe, :heartbeat_at)

      def self.run(options = {})
        new(options).run
      end

      def initialize(options = {})
        @options = options.compact
        @workers_count = options.fetch(:workers, 1).to_i
        @workers = {}
        @worker_read_pipes = []
        @terminate = false
      end

      def stop
        Process.kill('KILL', Process.pid) if @terminate == true

        Unity::CQMQ.log_queue << 'launcher stopping requested'
        @terminate = true
      end

      def run
        Unity::CQMQ.logger.info "spawning #{@workers_count} worker(s)..."
        @workers_count.times do |worker_idx|
          worker_entry = WorkerEntry.new(nil, worker_idx, IO.pipe, Time.now.to_i)
          @worker_read_pipes << worker_entry.pipe[0]
          worker_entry.pid = spawn_worker(worker_entry)

          @workers[worker_idx] = worker_entry
        end

        Signal.trap('INT') { stop }
        Signal.trap('TERM') { stop }

        Process.setproctitle("unity-cqmq v#{Unity::CQMQ::VERSION} (master)")

        health_check_thr = Thread.start do
          loop do
            result = IO.select(@worker_read_pipes, nil, nil, 5)
            next if result.nil?

            result[0].each do |io|
              str = io.read_nonblock(1024)
              case str[0]
              when 'H'
                str_split = str.split('$')
                worker = @workers[str_split[1].to_i]
                worker.heartbeat_at = Time.now.to_i
                Unity::CQMQ.logger&.debug "recv heartbeat from worker ##{worker.index}"
              end
            rescue IO::WaitReadable
              next
            end
          rescue StandardError => e
            Unity::CQMQ.logger&.error(
              "[health-check-thread] uncaught exception: #{e.message} (#{e.class}"
            )
            sleep 5
            next
          end
        end

        loop do
          break if @terminate == true

          dead_workers = []
          @workers.each_value do |worker|
            next if worker.heartbeat_at + 30 > Time.now.to_i

            dead_workers << worker
          end

          dead_workers.each do |worker|
            Unity::CQMQ.logger&.debug "respawn worker ##{worker.index}"
            kill_worker(worker.pid, 'KILL')
            @workers[worker.index].pid = spawn_worker(worker)
          end

          sleep 5
        end

        @workers.each_value do |worker|
          Unity::CQMQ.logger.debug "terminating worker ##{worker.index} (#{worker.pid})..."
          kill_worker(worker.pid)
        end
      end

      private

      def kill_worker(worker_pid, sig = 'TERM')
        Process.kill(sig, worker_pid)
        Process.wait(worker_pid)
      rescue Errno::ECHILD, Errno::ESRCH
        # do nothing
      end


      def spawn_worker(worker_entry)
        Unity::CQMQ.logger.debug "start worker ##{worker_entry.index}..."
        launcher_pid = Process.pid
        pid = fork do
          Process.setproctitle("  |> unity-cqmq worker ##{worker_entry.index}")
          processor = Unity::CQMQ::Processor.new(@options.merge(name: "worker-#{worker_entry.index}"))

          # check launcher process
          Thread.start(processor) do |pro|
            loop do
              begin
                Process.kill(0, launcher_pid)
              rescue Errno::ESRCH
                break
              end

              worker_entry.pipe[1].puts("H$#{worker_entry.index}")

              sleep 5
            end

            pro.stop
          end

          processor.run
        end
        Process.detach(pid)
        pid
      end
    end
  end
end
