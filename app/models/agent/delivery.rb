require "net/http"
require "uri"

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

    # Shared work payload for event polling and the webhook. The url is
    # the workspace permalink path for the thread, the same form thread
    # push notifications use; agents combine it with their configured
    # host. The thread_id, status, and assigned_by keys predate the
    # shared builder and keep their names; everything else comes from it.
    def work_payload(thread, assigned_by:)
      Agents::WorkPayload.for(thread).merge(
        thread_id: thread.id,
        status: thread.work_status,
        assigned_by: assigned_by
      )
    end

    # Posts a work assignment change to the agent's webhook. The payload
    # carries the same additive agent key as other deliveries plus the
    # event type (work_assigned or work_unassigned) and a work key with
    # the thread fields. Response bodies are ignored: an assignment
    # notification never creates a reply message.
    def post_work_webhook!(webhook, event, thread:, agent:)
      uri = URI(webhook.url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == "https")
      http.open_timeout = Webhook::ENDPOINT_TIMEOUT
      http.read_timeout = Webhook::ENDPOINT_TIMEOUT

      payload = {
        agent: { id: agent.id, name: agent.user.name, owner: agent.owner&.name, delivery_id: event.id },
        event_type: event.event_type,
        work: work_payload(thread, assigned_by: event.metadata.is_a?(Hash) ? event.metadata["assigned_by"] : nil)
      }.to_json

      http.request(Net::HTTP::Post.new(uri, "Content-Type" => "application/json").tap { |request| request.body = payload })
    end

    # Posts an approval decision to the agent's webhook. The payload carries
    # the same additive agent key as message deliveries plus an approval key
    # with the decision fields. Response bodies are ignored: a decision
    # notification never creates a reply message.
    def post_approval_webhook!(webhook, approval, agent:, delivery_id:)
      uri = URI(webhook.url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == "https")
      http.open_timeout = Webhook::ENDPOINT_TIMEOUT
      http.read_timeout = Webhook::ENDPOINT_TIMEOUT

      payload = {
        agent: { id: agent.id, name: agent.user.name, owner: agent.owner&.name, delivery_id: delivery_id },
        approval: {
          approval_id: approval.id,
          status: approval.status,
          decided_by: approval.decided_by&.name,
          note: approval.decision_note
        }
      }.to_json

      http.request(Net::HTTP::Post.new(uri, "Content-Type" => "application/json").tap { |request| request.body = payload })
    end

    # Posts a GitHub write-action result to the agent's webhook. The payload
    # carries the same additive agent key as approval decisions plus a
    # github_action key with the completion fields. Response bodies are
    # ignored: a completion notification never creates a reply message.
    def post_github_action_webhook!(webhook, event, agent:)
      uri = URI(webhook.url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == "https")
      http.open_timeout = Webhook::ENDPOINT_TIMEOUT
      http.read_timeout = Webhook::ENDPOINT_TIMEOUT

      metadata = event.metadata.is_a?(Hash) ? event.metadata : {}
      payload = {
        agent: { id: agent.id, name: agent.user.name, owner: agent.owner&.name, delivery_id: event.id },
        github_action: {
          approval_id: metadata["approval_id"],
          action: metadata["action"],
          status: metadata["status"],
          url: metadata["url"],
          message: metadata["message"]
        }.compact
      }.to_json

      http.request(Net::HTTP::Post.new(uri, "Content-Type" => "application/json").tap { |request| request.body = payload })
    end

    # Runs inside Agent::DeliveryJob. Re-checks everything at perform time:
    # grant, membership, rate, hop, and message existence. Marks the row
    # delivered (posting the webhook when configured) or records a
    # suppression. Idempotent: non-pending rows are left alone.
    def perform(event)
      event = AgentEvent.find_by(id: event.is_a?(AgentEvent) ? event.id : event)
      return unless event
      return unless event.outcome == "pending"
      return unless AgentEvent::MESSAGE_DELIVERABLE_TYPES.include?(event.event_type)

      agent = event.agent
      room = Room.find_by(id: event.room_id)
      message = Message.find_by(id: event.message_id)

      if message.nil? || room.nil?
        claim(event, outcome: "suppressed", detail: "Message no longer available")
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

      return unless claim(event, outcome: "delivered")

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
      # the chain of its server-authorized trigger: the most recent event
      # delivered to (or acknowledged by) the agent in the room within the
      # trigger window. The agent's own posted rows, suppression rows,
      # approval decisions, and pending rows are never triggers, so an agent
      # posting several unprompted messages does not escalate its own hop
      # count, and neither the request body nor the reply target influences
      # the hop. A message with no recent trigger is a new root at hop 0.
      def message_hop_for(message, sender_agent)
        return 0 unless sender_agent

        trigger = sender_agent.agent_events.message_deliverable
          .where(room_id: message.room_id, outcome: %w[ delivered acknowledged ])
          .where("created_at >= ?", TRIGGER_WINDOW.ago)
          .order(id: :desc).first
        trigger ? trigger.hop + 1 : 0
      end

      def rate_limited?(agent, room, exclude: nil)
        scope = agent.agent_events.message_deliverable
          .where(room_id: room.id)
          .where("created_at >= ?", RATE_WINDOW.ago)
          .where(outcome: %w[ pending delivered acknowledged ])
        scope = scope.where.not(id: exclude.id) if exclude
        scope.count >= RATE_LIMIT_PER_MINUTE
      end

      def member_of?(agent, room)
        Membership.exists?(user_id: agent.user_id, room_id: room.id)
      end

      # Atomically transitions a pending row; false when another job
      # already claimed it, so two concurrent jobs cannot both post and the
      # loser exits without posting or writing a duplicate suppression row.
      def claim(event, outcome:, detail: nil)
        updates = { outcome: outcome }
        updates[:detail] = detail unless detail.nil?
        AgentEvent.where(id: event.id, outcome: "pending").update_all(updates) == 1
      end

      def suppress(event, event_type, detail)
        return unless claim(event, outcome: "suppressed", detail: detail)

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
