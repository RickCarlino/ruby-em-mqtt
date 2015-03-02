
class EventMachine::MQTT::ClientConnection < EventMachine::MQTT::Connection
  include EventMachine::Deferrable

  attr_reader :client_id
  attr_reader :keep_alive
  attr_reader :clean_session
  attr_reader :packet_id
  attr_reader :ack_timeout
  attr_reader :timer

  # FIXME: change this to optionally take hash of options
  def self.connect(host=MQTT::DEFAULT_HOST, port=MQTT::DEFAULT_PORT, *args, &blk)
    EventMachine.connect( host, port, self, *args, &blk )
  end

  def post_init
    super
    @state = :connecting
    @client_id = MQTT::Client.generate_client_id
    @keep_alive = 10
    @clean_session = true
    @packet_id = 0
    @ack_timeout = 5
    @timer = nil
  end

  def connection_completed
    # Protocol name and version
    packet = MQTT::Packet::Connect.new(
      :clean_session => @clean_session,
      :keep_alive => @keep_alive,
      :client_id => @client_id
    )

    send_packet(packet)

    @state = :connect_sent
  end

  # Disconnect from the MQTT broker.
  # If you don't want to say goodbye to the broker, set send_msg to false.
  def disconnect(send_msg=true)
    # FIXME: only close if we aren't waiting for any acknowledgements
    if connected?
      send_packet(MQTT::Packet::Disconnect.new) if send_msg
    end
    @state = :disconnecting
  end

  def receive_callback(&block)
    @receive_callback = block
  end

  def receive_msg(packet)
    # Alternatively, subclass this method
    @receive_callback.call(packet) unless @receive_callback.nil?
  end

  def unbind
    timer.cancel if timer
    unless state == :disconnecting
      raise MQTT::NotConnectedException.new("Connection to server lost")
    end
    @state = :disconnected
  end

  # Publish a message on a particular topic to the MQTT broker.
  def publish(topic, payload, retain=false, qos=0)
    # Defer publishing until we are connected
    callback do
      send_packet(
        MQTT::Packet::Publish.new(
          :id => next_packet_id,
          :qos => qos,
          :retain => retain,
          :topic => topic,
          :payload => payload
        )
      )
    end
  end

  # Send a subscribe message for one or more topics on the MQTT broker.
  def subscribe(*topics)
    # Defer subscribing until we are connected
    callback do
      send_packet(
        MQTT::Packet::Subscribe.new(
          :id => next_packet_id,
          :topics => topics
        )
      )
    end
  end

  # Send a unsubscribe message for one or more topics on the MQTT broker
  def unsubscribe(*topics)
    # Defer unsubscribing until we are connected
    callback do
      send_packet(
        MQTT::Packet::Unsubscribe.new(
          :id => next_packet_id,
          :topics => topics
        )
      )
    end
  end



private

  def process_packet(packet)
    if state == :connect_sent and packet.class == MQTT::Packet::Connack
      connect_ack(packet)
    elsif state == :connected and packet.class == MQTT::Packet::Pingresp
      # Pong!
    elsif state == :connected and packet.class == MQTT::Packet::Publish
      receive_msg(packet)
    elsif state == :connected and packet.class == MQTT::Packet::Suback
      # Subscribed!
    else
      # FIXME: deal with other packet types
      raise MQTT::ProtocolException.new(
        "Wasn't expecting packet of type #{packet.class} when in state #{state}"
      )
      disconnect
    end
  end

  def connect_ack(packet)
    if packet.return_code != 0x00
      raise MQTT::ProtocolException.new(packet.return_msg)
    else
      @state = :connected
    end

    # Send a ping packet every X seconds
    if keep_alive > 0
      @timer = EventMachine::PeriodicTimer.new(keep_alive) do
        send_packet MQTT::Packet::Pingreq.new
      end
    end

    # We are now connected - can now execute deferred calls
    set_deferred_success
  end

  def next_packet_id
    @packet_id += 1
  end

end
