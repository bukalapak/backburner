require 'tcp_timeout'
require 'backburner/job'

module Backburner
  #
  # @abstract Subclass and override {#process_tube_names}, {#prepare} and {#start} to implement
  #   a custom Worker class.
  #
  class Worker
    include Backburner::Helpers
    include Backburner::Logger

    # Backburner::Worker.known_queue_classes
    # List of known_queue_classes
    class << self
      attr_writer :known_queue_classes
      def known_queue_classes; @known_queue_classes ||= []; end
    end

    # Enqueues a job to be processed later by a worker.
    # Options: `pri` (priority), `delay` (delay in secs), `ttr` (time to respond), `queue` (queue name)
    #
    # @raise [Beaneater::NotConnected] If beanstalk fails to connect.
    # @example
    #   Backburner::Worker.enqueue NewsletterSender, [self.id, user.id], :ttr => 1000
    #
    def self.enqueue(job_class, args=[], opts={})
      pri   = resolve_priority(opts[:pri] || job_class)
      delay = [0, opts[:delay].to_i].max
      ttr   = resolve_respond_timeout(opts[:ttr] || job_class)
      res   = Backburner::Hooks.invoke_hook_events(job_class, :before_enqueue, *args)

      return nil unless res # stop if hook is false

      data = { :class => job_class.name, :args => args }
      queue = opts[:queue] && (Proc === opts[:queue] ? opts[:queue].call(job_class) : opts[:queue])

      begin
        response = nil
        max_retry = 10
        retry_count = 1

        @connection = current_pool.pick_connection
        until @connection.allow_request? || retry_count > max_retry
          current_pool.deactivate(@connection)
          @connection = current_pool.pick_connection
          retry_count = retry_count + 1
        end

        # raise if trying more than 10 times but still get broken connection
        raise "Circuit is open! At beanstalk #{@connection.url}" unless @connection.allow_request?

        @connection.retryable do
          tube = @connection.tubes[expand_tube_name(queue || job_class)]
          response = tube.put(data.to_json, :pri => pri, :delay => delay, :ttr => ttr)
          @connection.success!
        end

        return nil unless Backburner::Hooks.invoke_hook_events(job_class, :after_enqueue, *args)
      rescue Beaneater::TimedOutError
        @connection.fail!
        retry
      rescue  TCPTimeout::SocketTimeout, Beaneater::NotConnected => e
        @connection.fail!
        current_pool.deactivate(@connection)
        retry
      end

      response
    end

    def self.current_pool
      pool = Thread.current[:beanstalkd_connection_pool]
      unless pool && pool.alive?
        pool = Backburner::ConnectionPool.new(Backburner.configuration.beanstalk_url, Backburner.configuration.timeout_options) do |conn|
          Backburner::Hooks.invoke_hook_events(self, :on_reconnect, conn)
        end
        Thread.current[:beanstalkd_connection_pool] = pool
      end
      pool
    end

    # Starts processing jobs with the specified tube_names.
    #
    # @example
    #   Backburner::Worker.start(["foo.tube.name"])
    #
    def self.start(tube_names=nil)
      begin
        self.new(tube_names).start
      rescue SystemExit
        # do nothing
      end
    end

    # List of tube names to be watched and processed
    attr_accessor :tube_names, :connection_pool

    # Constructs a new worker for processing jobs within specified tubes.
    #
    # @example
    #   Worker.new(['test.job'])
    def initialize(tube_names=nil)
      @connection_pool = new_connection_pool
      @tube_names = self.process_tube_names(tube_names)
      register_signal_handlers!
    end

    # Starts processing ready jobs indefinitely.
    # Primary way to consume and process jobs in specified tubes.
    #
    # @example
    #   @worker.start
    #
    def start
      raise NotImplementedError
    end

    # Used to prepare the job queues before job processing is initiated.
    #
    # @raise [Beaneater::NotConnected] If beanstalk fails to connect.
    # @example
    #   @worker.prepare
    #
    # @abstract Define this in your worker subclass
    # to be run once before processing. Recommended to watch tubes
    # or print a message to the logs with 'log_info'
    #
    def prepare
      raise NotImplementedError
    end

    # Triggers this worker to shutdown
    def shutdown
      Thread.new do
        log_info 'Worker exiting...'
      end
      Kernel.exit
    end

    # Processes tube_names given tube_names array.
    # Should return normalized tube_names as an array of strings.
    #
    # @example
    #   process_tube_names([['foo'], ['bar']])
    #   => ['foo', 'bar', 'baz']
    #
    # @note This method can be overridden in inherited workers
    # to add more complex tube name processing.
    def process_tube_names(tube_names)
      compact_tube_names(tube_names)
    end

    # Performs a job by reserving a job from beanstalk and processing it
    #
    # @example
    #   @worker.work_one_job
    # @raise [Beaneater::NotConnected] If beanstalk fails to connect multiple times.
    def work_one_job(pool = connection_pool)
      begin
        conn = pool.pick_connection
        job = reserve_job(conn)
      rescue Beaneater::TimedOutError => e
        return
      rescue ::TCPTimeout::SocketTimeout
        pool.deactivate(conn)
        return
      rescue Beaneater::NotConnected
        pool.deactivate(conn)
        return
      rescue Backburner::ConnectionPool::NoActiveConnection
        pool.reconnect_with_backoff
        return
      end

      self.log_job_begin(job.name, job.args, conn)
      job.process
      self.log_job_end(job.name, nil, conn)
      pool.success = true

    rescue Backburner::Job::JobFormatInvalid => e
      self.log_error self.exception_message(e)
    rescue Beaneater::NotFoundError
      pool.deactivate(conn)
      return
    rescue Beaneater::TimedOutError => e
      return
    rescue => e # Error occurred processing job
      begin
        e = Backburner::Job::DroppedJobError.new(e) if queue_config.max_job_buries >= 0 && job&.stats&.buries.to_i >= queue_config.max_job_buries
        self.log_error self.exception_message(e)

        unless job
          self.log_error "Error occurred before we were able to assign a job. Giving up without retrying!"
          return
        end

        # NB: There's a slight chance here that the connection to beanstalkd has
        # gone down between the time we reserved / processed the job and here.
        num_retries = job.stats.releases
        retry_status = "failed: attempt #{num_retries+1} of #{queue_config.max_job_retries+1}"
        if num_retries < queue_config.max_job_retries # retry again
          delay = queue_config.retry_delay_proc.call(queue_config.retry_delay, num_retries) rescue queue_config.retry_delay
          job.retry(num_retries + 1, delay)
          self.log_job_end(job.name, "#{retry_status}, retrying in #{delay}s", conn) if job_started_at
        elsif queue_config.max_job_buries >= 0 && job.stats.buries >= queue_config.max_job_buries # too many buries, drop the job
          job.drop(e)
          self.log_job_end(job.name, "failed: bury limit (#{queue_config.max_job_buries}) exceeded, dropping", conn) if job_started_at
        else # retries failed, bury
          job.bury
          self.log_job_end(job.name, "#{retry_status}, burying", conn) if job_started_at
        end
        handle_error(e, job.name, job.args, job)
      rescue Exception => e
        return
      end

    end


    protected

    # Return a new connection instance
    def new_connection_pool(worker = false)
      urls = worker ? Backburner.configuration.beanstalk_worker_url : Backburner.configuration.beanstalk_url
      Backburner::ConnectionPool.new(urls, Backburner.configuration.timeout_options) { |conn| Backburner::Hooks.invoke_hook_events(self, :on_reconnect, conn) }
    end

    # Reserve a job from the watched queues
    def reserve_job(conn, reserve_timeout = Backburner.configuration.reserve_timeout)
      Backburner::Job.new(conn.tubes.reserve(reserve_timeout))
    end

    # Returns a list of all tubes known within the system
    # Filtered for tubes that match the known prefix
    def all_existing_queues
      known_queues    = Backburner::Worker.known_queue_classes.map(&:queue)
      existing_tubes  = self.connection_pool.connections.map{|conn| conn.tubes.all.map(&:name) }.flatten.select { |tube| tube =~ /^#{queue_config.tube_namespace}/ }
      existing_tubes + known_queues + [queue_config.primary_queue]
    end


    # Handles an error according to custom definition
    # Used when processing a job that errors out
    def handle_error(e, name, args, job)
      if error_handler = Backburner.configuration.on_error
        if error_handler.arity == 1
          error_handler.call(e)
        elsif error_handler.arity == 3
          error_handler.call(e, name, args)
        else
          error_handler.call(e, name, args, job)
        end
      end
    end

    # Normalizes tube names given array of tube_names
    # Compacts nil items, flattens arrays, sets tubes to nil if no valid names
    # Loads default tubes when no tubes given.
    def compact_tube_names(tube_names)
      tube_names = tube_names.first if tube_names && tube_names.size == 1 && tube_names.first.is_a?(Array)
      tube_names = Array(tube_names).compact if tube_names && Array(tube_names).compact.size > 0
      tube_names = nil if tube_names && tube_names.compact.empty?
      tube_names ||= Backburner.default_queues.any? ? Backburner.default_queues : all_existing_queues
      Array(tube_names).uniq
    end

    # Registers signal handlers TERM and INT to trigger
    def register_signal_handlers!
      trap('TERM') { shutdown  }
      trap('INT')  { shutdown  }
    end
  end # Worker
end # Backburner
