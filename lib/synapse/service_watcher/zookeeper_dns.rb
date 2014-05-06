require 'synapse/service_watcher/base'
require 'synapse/service_watcher/dns'
require 'synapse/service_watcher/zookeeper'

require 'thread'

# Watcher for watching Zookeeper for entries containing DNS names that are
# continuously resolved to IP Addresses.  The use case for this watcher is to
# allow services that are addressed by DNS to be reconfigured via Zookeeper
# instead of an update of the synapse config.
#
# The implementation builds on top of the existing DNS and Zookeeper watchers.
# This watcher creates a thread to manage the lifecycle of the DNS and
# Zookeeper watchers.  This thread also publishes messages on a queue to
# indicate that DNS should be re-resolved (after the check interval) or that
# the DNS watcher should be shut down.  The Zookeeper watcher waits for changes
# in backends from zookeeper and publishes those changes on an internal queue
# consumed by the DNS watcher.  The DNS watcher blocks on this queue waiting
# for messages indicating that new servers are available, the check interval
# has passed (triggering a re-resolve), or that the watcher should shut down.
# The DNS watcher is responsible for the actual reconfiguring of backends.
module Synapse
  class ZookeeperDnsWatcher < BaseWatcher

    # Valid messages that can be passed through the internal message queue
    module Messages
      class InvalidMessageError < RuntimeError; end

      # Indicates new servers identified by DNS names to be resolved.  This is
      # sent from Zookeeper on events that modify the ZK node. The payload is
      # an array of hashes containing {'host', 'port', 'name'}
      class NewServers < Struct.new(:servers); end

      # Indicates that DNS should be re-resolved.  This is sent by the
      # ZookeeperDnsWatcher thread every check_interval seconds to cause a
      # refresh of the IP addresses.
      class CheckInterval; end

      # Indicates that the DNS watcher should shut down.  This is sent when
      # stop is called.
      class StopWatcher; end

      # Saved instances of message types with contents that cannot vary.  This
      # reduces object allocation.
      STOP_WATCHER_MESSAGE = StopWatcher.new
      CHECK_INTERVAL_MESSAGE = CheckInterval.new
    end

    class Dns < Synapse::DnsWatcher

      attr_accessor :discovery_servers

      def initialize(opts={}, synapse, message_queue)
        @message_queue = message_queue

        super(opts, synapse)
      end

      def stop
        @message_queue.push(Messages::STOP_WATCHER_MESSAGE)
      end

      def watch
        last_resolution = nil
        while true
          # Blocks on message queue, the message will be a signal to stop
          # watching, to check a new set of servers from ZK, or to re-resolve
          # the DNS (triggered every check_interval seconds)
          message = @message_queue.pop

          case message
          when Messages::StopWatcher
            break
          when Messages::NewServers
            self.discovery_servers = message.servers
          when Messages::CheckInterval
            # Proceed to re-resolve the DNS
          else
            raise Messages::InvalidMessageError,
              "Received unrecognized message: #{message.inspect}"
          end

          # Empty servers means we haven't heard back from ZK yet
          unless self.discovery_servers.nil? || self.discovery_servers.empty?
            # Resolve DNS names with the nameserver
            current_resolution = resolve_servers
            unless last_resolution == current_resolution
              last_resolution = current_resolution
              configure_backends(last_resolution)
            end
          end
        end
      end

      private

      # Validation is skipped as it has already occurred in the parent watcher
      def validate_discovery_opts
      end
    end

    class Zookeeper < Synapse::ZookeeperWatcher
      def initialize(opts={}, synapse, message_queue)
        super(opts, synapse)

        @message_queue = message_queue
      end

      # Overrides reconfigure! to cause the new list of servers to be messaged
      # to the DNS watcher rather than invoking a synapse reconfigure directly
      def reconfigure!
        # push the new backends onto the queue
        @message_queue.push(Messages::NewServers.new(@backends))
      end

      private

      # Validation is skipped as it has already occurred in the parent watcher
      def validate_discovery_opts
      end
    end

    def start
      dns_discovery_opts = @discovery.select do |k,_|
        k == 'nameserver' || k == 'default_servers'
      end

      zookeeper_discovery_opts = @discovery.select do |k,_|
        k == 'hosts' || k == 'path'
      end


      @check_interval = @discovery['check_interval'] || 30.0

      @message_queue = Queue.new

      @dns = Dns.new(
        mk_child_watcher_opts(dns_discovery_opts),
        @synapse,
        @message_queue
      )

      @zk = Zookeeper.new(
        mk_child_watcher_opts(zookeeper_discovery_opts),
        @synapse,
        @message_queue
      )

      @watcher = Thread.new do
        @zk.start
        @dns.start

        until @should_exit
          # Trigger a DNS resolve every @check_interval seconds
          sleep @check_interval

          # Only trigger the resolve if the queue is empty, every other message
          # on the queue would either cause a resolve or stop the watcher
          if @message_queue.empty?
            @message_queue.push(Messages::CHECK_INTERVAL_MESSAGE)
          end
        end
      end
    end

    def ping?
      @dns.ping? && @zk.ping?
    end

    def stop
      super

      @dns.stop
      @zk.stop
    end

    def backends
      @dns.backends
    end

    private

    def validate_discovery_opts
      unless @discovery['method'] == 'zookeeper_dns'
        raise ArgumentError, "invalid discovery method #{@discovery['method']}"
      end

      unless @discovery['hosts']
        raise ArgumentError, "missing or invalid zookeeper host for service #{@name}"
      end

      unless @discovery['path']
        raise ArgumentError, "invalid zookeeper path for service #{@name}"
      end
    end

    # Method to generate a full config for the children (Dns and Zookeeper)
    # watchers
    def mk_child_watcher_opts(discovery_opts)
      {
        'name' => @name,
        'haproxy' => @haproxy,
        'discovery' => discovery_opts,
      }
    end

    # Override reconfigure! as this class should not explicitly reconfigure
    # synapse
    def reconfigure!
    end
  end
end
