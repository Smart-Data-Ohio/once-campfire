class Event::ReminderDispatcher
  REMIND_BEFORE = 15.minutes
  REMIND_AFTER_GRACE = 60.minutes

  class << self
    # There is no delayed-job facility, so a loop runner calls this on an
    # interval. Claiming through reminded_at keeps a second run (or a second
    # runner) from notifying twice.
    def dispatch_due!(now: Time.current)
      due_events(now).find_each do |event|
        dispatch_event!(event, now:)
      rescue => error
        Rails.logger.error "Event reminder failed for event #{event.id}: #{error.class}: #{error.message}"
      end
    end

    private
      def due_events(now)
        Event.active
          .where(reminded_at: nil)
          .where(starts_at: (now - REMIND_AFTER_GRACE)..(now + REMIND_BEFORE))
      end

      def dispatch_event!(event, now:)
        claimed = event.with_lock do
          if event.reminded_at.present?
            false
          else
            event.remind_attendees!
            event.update!(reminded_at: now)
            true
          end
        end

        Event::ReminderPushJob.perform_later(event) if claimed
      end
  end
end
