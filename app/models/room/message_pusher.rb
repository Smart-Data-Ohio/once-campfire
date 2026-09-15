class Room::MessagePusher
  attr_reader :room, :message

  def initialize(room:, message:)
    @room, @message = room, message
  end

  def push
    enqueue_payload_for_delivery build_payload, push_subscriptions_for_recipients
  end

  private
    def build_payload
      if room.direct?
        build_direct_payload
      else
        build_shared_payload
      end
    end

    def build_direct_payload
      {
        title: message.creator.name,
        body: message.plain_text_body,
        path: Rails.application.routes.url_helpers.room_path(room)
      }
    end

    def build_shared_payload
      {
        title: room.name,
        body: "#{message.creator.name}: #{message.plain_text_body}",
        path: Rails.application.routes.url_helpers.room_path(room)
      }
    end

    def push_subscriptions_for_recipients
      [
        push_subscriptions_for_users_involved_in_everything,
        push_subscriptions_for_mentionable_users(message.mentionees),
        push_subscriptions_for_reply_author
      ].compact.reduce { |subscriptions, recipients| subscriptions.or(recipients) }.distinct
    end

    def push_subscriptions_for_users_involved_in_everything
      relevant_subscriptions.merge(Membership.involved_in_everything)
    end

    def push_subscriptions_for_mentionable_users(mentionees)
      relevant_subscriptions.merge(Membership.involved_in_mentions).where(user_id: mentionees.ids)
    end

    # Reply authors should receive an opted-in direct notification even when
    # they follow the room at "mentions". A reply is one delivery regardless
    # of whether that user was also directly mentioned or follows everything.
    def push_subscriptions_for_reply_author
      reply_author_id = message.reply_to_message&.creator_id
      return if reply_author_id.blank? || reply_author_id == message.creator_id || !message.reply_notify_author?

      relevant_subscriptions
        .merge(Membership.where.not(involvement: %w[ invisible nothing ]))
        .where(user_id: reply_author_id)
    end

    def relevant_subscriptions
      Push::Subscription
        .joins(user: :memberships)
        .merge(Membership.visible.disconnected.where(room: room).where.not(user: message.creator))
    end

    def enqueue_payload_for_delivery(payload, subscriptions)
      Rails.configuration.x.web_push_pool.queue(payload, subscriptions)
    end
end
