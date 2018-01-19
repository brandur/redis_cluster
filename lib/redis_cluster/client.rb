require 'thread'

module RedisCluster

  class Client

    def initialize(startup_hosts, configs = {})
      @startup_hosts = startup_hosts

      # Extract configuration options relevant to Redis Cluster.

      # force_cluster defaults to true to match the client's behavior before
      # the option existed
      @force_cluster = configs.delete(:force_cluster) { |_key| true }

      # Any leftover configuration goes through to the pool and onto individual
      # Redis clients.
      @pool = Pool.new(configs)
      @mutex = Mutex.new

      reload_pool_nodes(true)
    end

    def execute(method, args, &block)
      ttl = Configuration::REQUEST_TTL
      asking = false
      try_random_node = false

      while ttl > 0
        ttl -= 1
        begin
          return @pool.execute(method, args, {asking: asking, random_node: try_random_node}, &block)
        rescue Errno::ECONNREFUSED, Redis::TimeoutError, Redis::CannotConnectError, Errno::EACCES
          try_random_node = true
          sleep 0.1 if ttl < Configuration::REQUEST_TTL / 2
        rescue => e
          err_code = e.to_s.split.first
          raise e unless %w(MOVED ASK).include?(err_code)

          if err_code == 'ASK'
            asking = true
          else
            reload_pool_nodes(false)
            sleep 0.1 if ttl < Configuration::REQUEST_TTL / 2
          end
        end
      end
    end

    Configuration.method_names.each do |method_name|
      define_method method_name do |*args, &block|
        execute(method_name, args, &block)
      end
    end

    def method_missing(method, *args, &block)
      execute(method, args, &block)
    end

    private

    # Adds only a single node to the client pool and sets it result for the
    # entire space of slots. This is useful when running either a standalone
    # Redis or a single-node Redis Cluster.
    def create_single_node_pool
      host = @startup_hosts
      if host.is_a?(Array)
        if host.length > 1
          raise ArgumentError, "Can only create single node pool for single host"
        end

        # Flatten the configured host so that we can easily add it to the
        # client pool.
        host = host.first
      end

      @pool.add_node!(host, [(0..Configuration::HASH_SLOTS)])
    end

    def create_multi_node_pool(raise_error)
      unless @startup_hosts.is_a?(Array)
        raise ArgumentError, "Can only create multi-node pool for multiple hosts"
      end

      @startup_hosts.each do |options|
        begin
          redis = Node.redis(@pool.global_configs.merge(options))
          slots_mapping = redis.cluster("slots").group_by{|x| x[2]}
          @pool.delete_except!(slots_mapping.keys)
          slots_mapping.each do |host, infos|
            slots_ranges = infos.map {|x| x[0]..x[1] }
            @pool.add_node!({host: host[0], port: host[1]}, slots_ranges)
          end
        rescue Redis::CommandError => e
          if e.message =~ /cluster\ support\ disabled$/
            if !@force_cluster
              # We're running outside of cluster-mode -- just create a
              # single-node pool and move on. The exception is if we've been
              # asked for force Redis Cluster, in which case we assume this is
              # a configuration problem and maybe raise an error.
              create_single_node_pool
              return
            elsif raise_error
              raise e
            end
          end

          raise e if e.message =~ /NOAUTH\ Authentication\ required/

          # TODO: log error for visibility
          next
        rescue
          # TODO: log error for visibility
          next
        end

        # We only need to see a `CLUSTER SLOTS` result from a single host, so
        # break after one success.
        break
      end
    end

    # Reloads the client node pool by requesting new information with `CLUSTER
    # SLOTS` or just adding a node directly if running on standalone. Clients
    # are "upserted" so that we don't necessarily drop clients that are still
    # relevant.
    def reload_pool_nodes(raise_error)
      @mutex.synchronize do
        if @startup_hosts.is_a?(Array)
          create_multi_node_pool(raise_error)
          refresh_startup_nodes
        else
          create_single_node_pool
        end
      end
    end

    # Refreshes the contents of @startup_hosts based on the hosts currently in
    # the client pool. This is useful because we may have been told about new
    # hosts after running `CLUSTER SLOTS`.
    def refresh_startup_nodes
      @pool.nodes.each {|node| @startup_hosts.push(node.host_hash) }
      @startup_hosts.uniq!
    end

  end # end client

end
