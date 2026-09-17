class Agent::Delivery
  RATE_LIMIT_PER_MINUTE = 20
  RATE_WINDOW = 1.minute
  HOP_LIMIT = 3
  TRIGGER_WINDOW = 5.minutes

  class << self
    # Called after a message commits. Writes a `posted` row when the author
    # is an agent, then creates one pending event per recipient agent (or a
    # suppression row when rate- or hop-limited) and enqueues delivery jobs.
    def enqueue_for_message(message)
      room = message.room
      return unless room

      sender_agent = Agent.find_by(user_id: message.creator_id)
      message_hop = message_hop_for(message, sender_agent)

      if sender_agent
        sender_agent.agent_events.create!(
          event_type: "posted",
          room: room,
          message: message,
          actor_id: message.creator_id,
          outcome: "delivered",
          metadata: { "hop" => message_hop }
        )
      end

      recipients_for(message).each do |agent, event_type|
        if message_hop >= HOP_LIMIT
          agent.agent_events.create!(
            event_type: "delivery_suppressed_hop_limit",
            room: room,
            message: message,
            actor_id: message.creator_id,
            outcome: "suppressed",
            detail: "Hop limit reached (hop #{message_hop})",
            metadata: { "hop" => message_hop }
          )
          next
        end

        if rate_limited?(agent, room)
          agent.agent_events.create!(
            event_type: "delivery_suppressed_rate_limit",
            room: room,
            message: message,
            actor_id: message.creator_id,
            outcome: "suppressed",
            detail: "Rate limit exceeded (#{RATE_LIMIT_PER_MINUTE} per minute)",
            metadata: { "hop" => message_hop }
          )
          next
        end

        event = agent.agent_events.create!(
          event_type: event_type,
          room: room,
          message: message,
          actor_id: message.creator_id,
          outcome: "pending",
          metadata: { "hop" => message_hop }
        )
        Agent::DeliveryJob.perform_later(event.id)
      end
    end

    # Runs inside Agent::DeliveryJob. Re-checks everything at perform time:
    # grant, membership, rate, hop, and message existence. Marks the row
    # delivered (posting the webhook when configured) or records a
    # suppression. Idempotent: non-pending rows are left alone.
    def perform(event)
      event = AgentEvent.find_by(id: event.is_a?(AgentEvent) ? event.id : event)
      return unless event
      return unless event.outcome == "pending"
      return unless event.deliverable?

      agent = event.agent
      room = Room.find_by(id: event.room_id)
      message = Message.find_by(id: event.message_id)

      if message.nil? || room.nil?
        event.update!(outcome: "suppressed", detail: "Message no longer available")
        return
      end

      unless agent.active? && member_of?(agent, room) && agent.can?(:read_messages, room)
        suppress(event, "delivery_suppressed_revoked", "Grant revoked or room access removed")
        return
      end

      if event.hop >= HOP_LIMIT
        suppress(event, "delivery_suppressed_hop_limit", "Hop limit reached (hop #{event.hop})")
        return
      end

      if rate_limited?(agent, room, exclude: event)
        suppress(event, "delivery_suppressed_rate_limit", "Rate limit exceeded (#{RATE_LIMIT_PER_MINUTE} per minute)")
        return
      end

      event.update!(outcome: "delivered")

      if (webhook = agent.user.webhook)
        begin
          webhook.deliver(message, agent: agent, delivery_id: event.id)
        rescue StandardError => error
          Rails.logger.warn "Agent webhook delivery #{event.id} failed: #{error.class}"
        end
      end
    end

    private
      # One entry per recipient agent: [agent, event_type]. Direct rooms
      # notify every other agent member; elsewhere a reply to an agent's
      # message wins over a mention when both apply to the same agent.
      def recipients_for(message)
        room = message.room
        agents_by_user_id = Agent.where(user_id: room.user_ids).index_by(&:user_id)
        return [] if agents_by_user_id.empty?

        if room.direct?
          agents_by_user_id.filter_map do |user_id, agent|
            next if user_id == message.creator_id

            [ agent, "direct_message" ]
          end
        else
          recipients = {}

          message.mentionees.each do |user|
            next if user.id == message.creator_id
            next unless (agent = agents_by_user_id[user.id])

            recipients[agent.id] ||= [ agent, "mention" ]
          end

          if (reply_source = message.reply_to_message) && reply_source.creator_id != message.creator_id
            if (agent = agents_by_user_id[reply_source.creator_id])
              recipients[agent.id] = [ agent, "reply" ]
            end
          end

          recipients.values
        end
      end

      # Human messages start a chain at hop 0. An agent's message continues
      # the chain of its server-authorized trigger: the agent's most recent
      # delivered or acknowledged event in the room within the trigger
      # window. Suppression rows and pending rows are never triggers, and
      # neither the request body nor the reply target influences the hop. A
      # message with no recent trigger is a new root at hop 0.
      def message_hop_for(message, sender_agent)
        return 0 unless sender_agent

        trigger = sender_agent.agent_events
          .where(room_id: message.room_id, outcome: %w[ delivered acknowledged ])
          .where("created_at >= ?", TRIGGER_WINDOW.ago)
          .order(id: :desc).first
        trigger ? trigger.hop + 1 : 0
      end

      def rate_limited?(agent, room, exclude: nil)
        scope = agent.agent_events.deliverable
          .where(room_id: room.id)
          .where("created_at >= ?", RATE_WINDOW.ago)
          .where(outcome: %w[ pending delivered acknowledged ])
        scope = scope.where.not(id: exclude.id) if exclude
        scope.count >= RATE_LIMIT_PER_MINUTE
      end

      def member_of?(agent, room)
        Membership.exists?(user_id: agent.user_id, room_id: room.id)
      end

      def suppress(event, event_type, detail)
        event.update!(outcome: "suppressed", detail: detail)
        event.agent.agent_events.create!(
          event_type: event_type,
          room_id: event.room_id,
          message_id: event.message_id,
          actor_id: event.actor_id,
          outcome: "suppressed",
          detail: detail,
          metadata: { "hop" => event.hop }
        )
      end
  end
end
