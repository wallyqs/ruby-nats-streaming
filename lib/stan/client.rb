require 'stan/pb/protocol.pb'
require 'nats/io/client'
require 'securerandom'
require 'monitor'

module STAN

  # Subject namespaces for clients to ack and connect
  DEFAULT_ACKS_SUBJECT     = "_STAN.acks".freeze
  DEFAULT_DISCOVER_SUBJECT = "_STAN.discover".freeze

  # Ack timeout in seconds
  DEFAULT_ACK_WAIT = 30

  # Max number of inflight acks
  DEFAULT_MAX_INFLIGHT = 1024

  # Connect timeout in seconds
  DEFAULT_CONNECT_TIMEOUT = 2

  # Max number of inflight pub acks
  DEFAULT_MAX_PUB_ACKS_INFLIGHT = 16384

  # Errors
  class Error < StandardError; end

  # When we detect we cannot connect to the server
  class ConnectError < Error; end

  # When we detect we have a request timeout
  class TimeoutError < Error; end

  class Client
    include MonitorMixin

    attr_reader :nats, :options, :client_id, :sub_map, :unsub_req_subject

    def initialize
      super

      # Connection to NATS, either owned or borrowed
      @nats = nil
      @borrowed_nats_connection = false

      # STAN subscriptions map
      @sub_map = {}

      # Publish Ack map (guid => ack)
      @pub_ack_map = {}

      # Cluster to which we are connecting
      @cluster_id = nil
      @client_id = nil

      # Inbox for period heartbeat messages
      @heartbeat_inbox = nil

      # Connect options
      @options = {}

      # NATS Streaming subjects

      # Publish prefix set by stan to which we append our subject on publish.
      @pub_prefix        = nil
      @sub_req_subject   = nil
      @unsub_req_subject = nil
      @close_req_subject = nil

      # For initial connect request to discover subjects used by
      # the streaming server.
      @discover_subject = nil

      # For processing received acks from the server
      @ack_subject = nil
    end

    # Plugs into a NATS Streaming cluster, establishing a connection
    # to NATS in case there is not one available to be borrowed.
    def connect(cluster_id, client_id, opts={}, &blk)
      @cluster_id = cluster_id
      @client_id  = client_id
      @options    = opts

      # Defaults
      @options[:connect_timeout] ||= DEFAULT_CONNECT_TIMEOUT

      # Prepare connect discovery request
      @discover_subject = "#{DEFAULT_DISCOVER_SUBJECT}.#{@cluster_id}".freeze

      # Prepare acks processing subscription
      @ack_subject = "#{DEFAULT_ACKS_SUBJECT}.#{STAN.create_guid}".freeze

      if @nats.nil?
        case options[:nats]
        when Hash
          # Custom NATS options in case borrowed connection not present
          # can be passed to establish a connection and have stan client
          # owning it.
          @nats = NATS::IO::Client.new
          nats.connect(options[:nats])
        when NATS::IO::Client
          @nats = options[:nats]
          @borrowed_nats_connection = true
        else
          # Try to connect with NATS defaults
          @nats = NATS::IO::Client.new
          nats.connect(servers: ["nats://127.0.0.1:4222"])
        end
      end

      # If no connection to NATS present at this point then bail already
      raise ConnectError.new("stan: invalid connection to nats") unless @nats

      # Heartbeat subscription
      @hb_inbox = (STAN.create_inbox).freeze

      # Setup acks and heartbeats processing callbacks
      nats.subscribe(@hb_inbox)    { |raw| process_heartbeats(raw) }
      nats.subscribe(@ack_subject) { |raw| process_ack(raw) }

      # Initial connect request to discover subjects to be used
      # for communicating with STAN.
      req = STAN::Protocol::ConnectRequest.new({
        clientID: @client_id,
        heartbeatInbox: @hb_inbox
      })

      # TODO: Check for error and bail if required
      raw = nats.request(@discover_subject, req.to_proto, timeout: options[:connect_timeout])
      resp = STAN::Protocol::ConnectResponse.decode(raw.data)
      @pub_prefix = resp.pubPrefix.freeze
      @sub_req_subject = resp.subRequests.freeze
      @unsub_req_subject = resp.unsubRequests.freeze
      @close_req_subject = resp.closeRequests.freeze

      # If callback given then we send a close request on exit
      # and wrap up session to STAN.
      if blk
        blk.call(self)

        # Close session to the STAN cluster
        close
      end
    end

    # Publish will publish to the cluster and wait for an ack
    def publish(subject, payload, opts={}, &blk)
      stan_subject = "#{@pub_prefix}.#{subject}"
      future = nil
      guid = STAN.create_guid

      pe = STAN::Protocol::PubMsg.new({
        clientID: @client_id,
        guid: guid,
        subject: subject,
        data: payload
      })

      if blk
        # Asynchronously handled if block given
        synchronize do
          # Map ack to guid
          @pub_ack_map[guid] = proc do |ack|
            # If block is given, handle the result asynchronously
            error = ack.error.empty? ? nil : Error.new(ack.error)
            case blk.arity
            when 0 then blk.call
            when 1 then blk.call(ack.guid)
            when 2 then blk.call(ack.guid, error)
            end

            @pub_ack_map.delete(ack.guid)
          end
          nats.publish(stan_subject, pe.to_proto, @ack_subject)
        end
      else
        # Waits for response before giving back control
        future = new_cond
        opts[:timeout] ||= DEFAULT_ACK_WAIT
        synchronize do
          # Map ack to guid
          ack_response = nil

          # FIXME: Maybe use fiber instead?
          @pub_ack_map[guid] = proc do |ack|
            # Capture the ack response
            ack_response = ack
            future.signal
          end

          # Send publish request and wait for the ack response
          nats.publish(stan_subject, pe.to_proto, @ack_subject)
          start_time = NATS::MonotonicTime.now
          future.wait(opts[:timeout])
          end_time = NATS::MonotonicTime.now
          if (end_time - start_time) > opts[:timeout]
            # Remove ack
            @pub_ack_map.delete(guid)
            raise TimeoutError.new("stan: timeout")
          end

          # Remove ack
          @pub_ack_map.delete(guid)
          return guid
        end
      end
      # TODO: Loop for processing of expired acks
    end

    # Create subscription which dispatches messages to callback asynchronously
    def subscribe(subject, opts={}, &cb)
      sub_options = {}
      sub_options.merge!(opts)
      sub_options[:ack_wait] ||= DEFAULT_ACK_WAIT
      sub_options[:max_inflight] ||= DEFAULT_MAX_INFLIGHT
      sub_options[:stan] = self

      sub = Subscription.new(subject, sub_options, cb)
      sub.extend(MonitorMixin)
      synchronize do
        @sub_map[sub.inbox] = sub
      end

      # Hold lock throughout
      sub.synchronize do
        # Listen for actual messages
        sid = nats.subscribe(sub.inbox) { |raw, reply, subject| process_msg(raw, reply, subject) }
        sub.sid = sid

        # Create the subscription request announcing the inbox on which
        # we have made the NATS subscription for processing messages.
        # First, we normalize customized subscription options before
        # encoding to protobuf.
        sub_opts = normalize_sub_req_params(sub_options)

        # Set STAN subject and NATS inbox where we will be awaiting
        # for the messages to be delivered.
        sub_opts[:subject] = subject
        sub_opts[:inbox] = sub.inbox

        sr = STAN::Protocol::SubscriptionRequest.new(sub_opts)
        reply = nil
        response = nil
        begin
          reply = nats.request(@sub_req_subject, sr.to_proto, timeout: DEFAULT_CONNECT_TIMEOUT)
          response = STAN::Protocol::SubscriptionResponse.decode(reply.data)
        rescue NATS::IO::Timeout, Google::Protobuf::ParseError => e
          # FIXME: Error handling on unsubscribe
          nats.unsubscribe(sub.sid)
          raise e
        end

        unless response.error.empty?
          # FIXME: Error handling on unsubscribe
          nats.unsubscribe(sub.sid)
          raise Error.new(response.error)
        end

        # Capture ack inbox for the subscription
        sub.ack_inbox = response.ackInbox.freeze

        return sub
      end
    end

    # Close wraps us the session with the NATS Streaming server
    def close
      req = STAN::Protocol::CloseRequest.new(clientID: @client_id)
      raw = nats.request(@close_req_subject, req.to_proto)

      resp = STAN::Protocol::CloseResponse.decode(raw.data)
      unless resp.error.empty?
        raise Error.new(resp.error)
      end

      # TODO: If connection to nats was borrowed then we should
      # unsubscribe from all topics from STAN.  If not borrowed
      # and we own the connection, then we just close.
      if @borrowed_nats_connection
        @nats = nil
      else
        @nats.close
      end
    end

    # Ack takes a received message and publishes an ack manually
    def ack(msg)
      return unless sub
      msg.sub.synchronize do
        ack_proto = STAN::Protocol::Ack.new({
          subject: msg.proto.subject,
          sequence: msg.proto.sequence
        }).to_proto
        nats.publish(msg.sub.ack_inbox, ack_proto)
      end
    rescue => e
      # TODO: Asynchronous error handling
    end

    private

    # Process received publishes acks
    def process_ack(data)
      # FIXME: This should handle errors asynchronously in case there are any

      # Process ack
      pub_ack = STAN::Protocol::PubAck.decode(data)
      unless pub_ack.error.empty?
        raise Error.new(pub_ack.error)
      end

      synchronize do
        # yield the ack response back to original publisher caller
        if cb = @pub_ack_map[pub_ack.guid]
          cb.call(pub_ack)
        end
      end
    rescue => e
      # TODO: Async error handler
    end

    # Process heartbeats by replying to them
    def process_heartbeats(data, reply, subject)
      # No payload assumed, just reply to the heartbeat.
      nats.publish(reply, '')
    rescue => e
      # TODO: Async error handler
    end

    # Process any received messages
    def process_msg(data, reply, subject)
      msg = Msg.new
      msg.proto = STAN::Protocol::MsgProto.decode(data)

      # Lookup the subscription
      sub = nil
      synchronize do
        sub = @sub_map[subject]
      end
      # Check if sub is no longer valid
      return unless sub

      # Store in msg for backlink
      msg.sub = sub

      cb = nil
      ack_subject = nil
      synchronize do
        cb = sub.cb
        ack_subject = sub.ack_inbox
        # TODO: is_manual_ack = sub.opts.manual_acks
      end

      # Perform the callback if sub still subscribed
      cb.call(msg) if cb

      # Process auto-ack
      # TODO: Manual ack?
      ack = STAN::Protocol::Ack.new({
        subject: msg.proto.subject,
        sequence: msg.proto.sequence
      })
      nats.publish(@ack_subject, ack.to_proto)

    rescue => e
      # TODO: Async error handler
    end

    def normalize_sub_req_params(opts)
      sub_opts = {}
      sub_opts[:qGroup] = opts[:queue] if opts[:queue]
      sub_opts[:durableName] = opts[:durable_name] if opts[:durable_name]

      sub_opts[:clientID] = @client_id
      sub_opts[:maxInFlight] = opts[:max_inflight]
      sub_opts[:ackWaitInSecs] = opts[:ack_wait] || opts[:ack_timeout]

      # TODO: Error checking when all combinations of options are not declared
      case opts[:start_at]
      when :new_only
        # By default, it already acts as :new_only which
        # without no initial replay, similar to bare NATS,
        # but we allow setting it explicitly anyway.
        sub_opts[:startPosition] = :NewOnly
      when :last_received
        sub_opts[:startPosition] = :LastReceived
      when :time, :timedelta
        # If using timedelta, need to get current time in UnixNano format
        # FIXME: Implement support for :ago option which uses time in human.
        sub_opts[:startPosition] = :TimeDeltaStart
        start_at_time = opts[:time] * 1_000_000_000
        sub_opts[:startTimeDelta] = (Time.now.to_f * 1_000_000_000) - start_at_time
      when :sequence
        sub_opts[:startPosition] = :SequenceStart
        sub_opts[:startSequence] = opts[:sequence] || 0
      when :first, :beginning
        sub_opts[:startPosition] = :First
      else
        sub_opts[:startPosition] = :First if opts[:deliver_all_available]
      end

      sub_opts
    end
  end

  class Subscription
    attr_reader :subject, :queue, :inbox, :options, :cb, :durable_name, :stan
    attr_accessor :sid, :ack_inbox

    def initialize(subject, opts={}, cb)
      @subject = subject
      @queue = opts[:queue]
      @inbox = STAN.create_inbox
      @sid = nil # inbox subscription sid
      @opts = opts
      @cb = cb
      @ack_inbox = nil
      @stan = opts[:stan]
      @durable_name = opts[:durable_name]
    end

    # Unsubscribe removes interest in the subscription.
    # For durables, it means that the durable interest is also removed from
    # the server. Restarting a durable with the same name will not resume
    # the subscription, it will be considered a new one.
    def unsubscribe
      # TODO: yield errors to async error handler

      synchronize do
        stan.nats.unsubscribe(self.sid)
      end

      # Make client stop tracking the subscription inbox
      # and grab unsub request subject under the lock.
      unsub_subject = nil
      stan.synchronize do
        stan.sub_map.delete(self.ack_inbox)
        unsub_subject = stan.unsub_req_subject
      end

      unsub_req = STAN::Protocol::UnsubscribeRequest.new({
        clientID: stan.client_id,
        subject: self.subject,
        inbox: self.ack_inbox
      })

      if self.durable_name
        unsub_req[:durableName] = self.durable_name
      end

      raw = stan.nats.request(unsub_subject, unsub_req.to_proto, {
        timeout: stan.options[:connect_timeout]
      })
      response = STAN::Protocol::SubscriptionResponse.decode(raw.data)
      unless response.error.empty?
        # FIXME: Error handling on unsubscribe
        raise Error.new(response.error)
      end
      p response
      # sub.ack_inbox = response.ackInbox.freeze
    end

    def close
      # TODO
    end
  end

  # Data holder for sent messages
  # It should have an Ack method as well to reply back?
  Msg = Struct.new(:proto, :sub) do
    def data
      self.proto.data
    end
    def sequence
      self.proto.sequence
    end
    alias seq sequence
  end

  class << self
    def create_guid
      SecureRandom.hex(11)
    end

    def create_inbox
      SecureRandom.hex(13)
    end
  end
end
