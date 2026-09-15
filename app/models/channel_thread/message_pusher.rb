class ChannelThread::MessagePusher
  attr_reader :thread, :message

  def initialize(thread:, message:)
    @thread, @message = thread, message
  end

  def push
    recipients.each do |recipient|
      enqueue_payload_for_user(recipient[:user], recipient[:payload])
    end
  end

  private
    def recipients
      parent_memberships = thread.room.memberships
      mention_ids = message.mentionees.ids
      reply_author_id = message.reply_to_message&.creator_id if message.reply_notify_author?
      reply_payload = build_reply_payload
      thread_payload = build_thread_payload
      candidates = {}

      thread.memberships.where.not(user_id: message.creator_id).find_each do |membership|
        room_membership = parent_memberships.find_by(user_id: membership.user_id)
        next unless room_membership && !room_membership.involved_in_invisible? && !room_membership.involved_in_nothing?
        next if membership.involved_in_nothing?

        if membership.involved_in_everything? || mention_ids.include?(membership.user_id)
          candidates[membership.user_id] = { user: membership.user, payload: thread_payload }
        end
      end

      if reply_author_id.present? && reply_author_id != message.creator_id
        membership = thread.memberships.find_by(user_id: reply_author_id)
        room_membership = parent_memberships.find_by(user_id: reply_author_id)
        if membership && room_membership && !room_membership.involved_in_invisible? && !room_membership.involved_in_nothing? && !membership.involved_in_nothing?
          candidates[reply_author_id] = { user: membership.user, payload: reply_payload }
        end
      end

      candidates.values
    end

    def build_thread_payload
      {
        title: thread.name,
        body: "#{message.creator.name}: #{message.plain_text_body}",
        path: Rails.application.routes.url_helpers.room_path(thread.room, thread: thread.id, message_id: message.id)
      }
    end

    def build_reply_payload
      {
        title: "Reply in #{thread.name}",
        body: "#{message.creator.name}: #{message.plain_text_body}",
        path: Rails.application.routes.url_helpers.room_path(thread.room, thread: thread.id, message_id: message.id)
      }
    end

    def enqueue_payload_for_user(user, payload)
      subscriptions = Push::Subscription.where(user_id: user.id)
      Rails.configuration.x.web_push_pool.queue(payload, subscriptions) if subscriptions.exists?
    end
end
