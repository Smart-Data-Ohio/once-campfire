class Huddle::InvitationPusher
  def initialize(activity_item:)
    @activity_item = activity_item
  end

  def push
    return unless grant && room && recipient && caller

    enqueue_payload_for_delivery build_payload, push_subscriptions_for_recipient
  end

  private
    def build_payload
      {
        title: "#{caller.name} started a huddle",
        body: "Join from the conversation",
        path: Rails.application.routes.url_helpers.room_path(room)
      }
    end

    # Mirrors Room::MessagePusher: only opted-in, disconnected memberships get
    # push. Connected sessions already ring through the in-app banner.
    def push_subscriptions_for_recipient
      Push::Subscription
        .joins(user: :memberships)
        .merge(Membership.visible.disconnected.where(room:, user: recipient).where.not(involvement: "nothing"))
    end

    def grant
      @grant ||= @activity_item.source if @activity_item.source_type == HuddleGrant.polymorphic_name
    end

    def room
      grant&.room
    end

    def recipient
      @activity_item.user
    end

    def caller
      grant&.user
    end

    def enqueue_payload_for_delivery(payload, subscriptions)
      Rails.configuration.x.web_push_pool.queue(payload, subscriptions)
    end
end
