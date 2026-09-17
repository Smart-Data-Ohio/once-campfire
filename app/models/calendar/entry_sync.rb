module Calendar
  # Reconciles one member's Google Calendar copy of one event with the
  # desired state computed from the database, so the sync job stays
  # idempotent: an entry exists exactly when the user is connected, is
  # going or maybe, the event is not cancelled, and the user is still a
  # room member. Failures are recorded on the entry for the next change
  # to retry; nothing here raises for Google or network problems.
  class EntrySync
    SYNCED_ATTRIBUTES = (Event::TIME_CHANGE_ATTRIBUTES + %w[ title description ]).freeze

    def self.sync(event_id, user_id)
      event = Event.find_by(id: event_id)
      user = User.find_by(id: user_id)
      return if event.nil? || user.nil?

      new(event, user).sync!
    end

    def initialize(event, user)
      @event = event
      @user = user
    end

    def sync!
      account = @user.google_account

      if desired?(account)
        upsert!(account)
      else
        remove!(account)
      end
    end

    private
      def desired?(account)
        account&.usable? &&
          @event.response_for(@user).in?(Event::NOTIFYING_RESPONSES) &&
          !@event.cancelled? &&
          @event.room.memberships.exists?(user_id: @user.id)
      end

      def upsert!(account)
        entry = EventCalendarEntry.find_or_initialize_by(event: @event, user: @user) do |new_entry|
          new_entry.google_event_id = SecureRandom.hex(16)
        end

        client = Google::Client.new(account)
        if entry.persisted?
          begin
            client.update_event(entry.google_event_id, payload)
          rescue Google::Client::NotFound
            client.insert_event(payload_with_id(entry))
          end
        else
          begin
            client.insert_event(payload_with_id(entry))
          rescue Google::Client::Conflict
            client.update_event(entry.google_event_id, payload)
          end
        end

        entry.synced_at = Time.current
        entry.last_error = nil
        entry.save!
      rescue StandardError => error
        entry.last_error = error_summary(error)
        entry.save!
        Rails.logger.warn "Calendar::EntrySync failed for event #{@event.id} user #{@user.id}: #{error.class}"
      end

      # A missing account (or one Google rejected) cannot call the API, so
      # the row is dropped without a request. A 404 from Google counts as
      # deleted. Other failures keep the row with last_error for a retry.
      def remove!(account)
        entry = EventCalendarEntry.find_by(event: @event, user: @user)
        return if entry.nil?

        if account&.usable?
          begin
            Google::Client.new(account).delete_event(entry.google_event_id)
          rescue Google::Client::NotFound
            nil
          rescue StandardError => error
            entry.update!(last_error: error_summary(error))
            Rails.logger.warn "Calendar::EntrySync delete failed for event #{@event.id} user #{@user.id}: #{error.class}"
            return
          end
        end

        entry.destroy!
      end

      def payload
        starts_at = @event.starts_at.in_time_zone(@event.time_zone)
        ends_at = (@event.ends_at || @event.starts_at + 1.hour).in_time_zone(@event.time_zone)

        {
          "summary" => @event.title,
          "description" => [ @event.description.presence, "From Campfire: #{event_url}" ].compact.join("\n\n"),
          "start" => { "dateTime" => starts_at.iso8601, "timeZone" => @event.time_zone },
          "end" => { "dateTime" => ends_at.iso8601, "timeZone" => @event.time_zone },
          "reminders" => { "useDefault" => true }
        }
      end

      def payload_with_id(entry)
        payload.merge("id" => entry.google_event_id)
      end

      def event_url
        helpers = Rails.application.routes.url_helpers
        if (host = Rails.application.routes.default_url_options[:host].presence)
          helpers.room_event_url(@event.room, @event, host:)
        else
          helpers.room_event_path(@event.room, @event)
        end
      end

      def error_summary(error)
        "#{error.class.name.demodulize}: #{error.message}".truncate(250)
      end
  end
end
