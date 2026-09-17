class Event::ReminderPusher
  attr_reader :event

  def initialize(event:)
    @event = event
  end

  def push
    enqueue_payload_for_delivery build_payload, push_subscriptions_for_recipients
  end

  private
    def build_payload
      body = "Starts in 15 minutes: #{event.title}"
      body += " in #{event.venue.name}" if event.venue.present?

      {
        title: event.room.direct? ? event.organizer.name : event.room.name,
        body:,
        path: Rails.application.routes.url_helpers.room_event_path(event.room, event)
      }
    end

    def push_subscriptions_for_recipients
      Push::Subscription.where(user_id: recipient_ids)
    end

    def recipient_ids
      User.active.without_bots
        .where(id: event.attendances.where(response: Event::NOTIFYING_RESPONSES).select(:user_id))
        .where(id: event.room.memberships.select(:user_id))
        .ids
    end

    def enqueue_payload_for_delivery(payload, subscriptions)
      Rails.configuration.x.web_push_pool.queue(payload, subscriptions)
    end
end
