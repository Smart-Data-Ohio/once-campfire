module Calendar
  # Reconciles one member's Google Calendar copy of one event with the
  # desired state computed from the database, so the sync job stays
  # idempotent: an entry exists exactly when the user is connected, is
  # going or maybe, the event is not cancelled, and the user is still a
  # room member. Failures are recorded on the entry for the next change
  # to retry; nothing here raises for Google or network problems.
  class EntrySync
    SYNCED_ATTRIBUTES = (Event::TIME_CHANGE_ATTRIBUTES + %w[ title description venue_room_id ]).freeze
    GOOGLE_EVENT_ID_PREFIX = "campfire"
    BASE32HEX_ALPHABET = "0123456789abcdefghijklmnopqrstuv"

    # Google event ids are deterministic per event and user ("campfire" +
    # base32hex of the packed ids), so concurrent first runs converge on
    # one remote event through the insert-conflict path instead of
    # duplicating it. Only [a-v0-9], within Google's 5..1024 limit.
    def self.google_event_id_for(event_id, user_id)
      bits = [ event_id, user_id ].pack("Q>Q>").unpack1("B*")
      encoded = bits.scan(/.{1,5}/).map { |chunk| BASE32HEX_ALPHABET[chunk.ljust(5, "0").to_i(2)] }.join
      "#{GOOGLE_EVENT_ID_PREFIX}#{encoded}"
    end

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

      # Reserves the local row before the first HTTP call so concurrent
      # runs share one deterministic id. The uniqueness validation fires
      # before the database constraint, so an existing row surfaces as
      # RecordInvalid here and is resolved with a second find.
      def reserve_entry!
        EventCalendarEntry.create_or_find_by!(event: @event, user: @user) do |new_entry|
          new_entry.google_event_id = self.class.google_event_id_for(@event.id, @user.id)
        end
      rescue ActiveRecord::RecordInvalid
        EventCalendarEntry.find_by!(event: @event, user: @user)
      end

      def upsert!(account)
        entry = reserve_entry!

        begin
          client = Google::Client.new(account)
          if entry.synced_at.nil?
            begin
              client.insert_event(payload_with_id(entry))
            rescue Google::Client::Conflict
              client.update_event(entry.google_event_id, payload)
            end
          else
            begin
              client.update_event(entry.google_event_id, payload)
            rescue Google::Client::NotFound
              client.insert_event(payload_with_id(entry))
            end
          end

          entry.synced_at = Time.current
          entry.last_error = nil
          entry.save!
        rescue StandardError => error
          if account.connected?
            entry.last_error = error_summary(error)
            entry.save!
            Rails.logger.warn "Calendar::EntrySync failed for event #{@event.id} user #{@user.id}: #{error.class}"
          else
            # The account disconnected mid-sync: the remote copy is
            # unreachable, so drop the local row instead of retrying it.
            entry.destroy!
            Rails.logger.warn "Calendar::EntrySync dropped entry for event #{@event.id} user #{@user.id}: account disconnected"
          end
        end
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
          "description" => [ @event.description.presence, "From Campfire: #{event_url}", join_line ].compact.join("\n\n"),
          "start" => { "dateTime" => starts_at.iso8601, "timeZone" => @event.time_zone },
          "end" => { "dateTime" => ends_at.iso8601, "timeZone" => @event.time_zone },
          "reminders" => { "useDefault" => true }
        }.merge(location_line)
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

      def join_line
        "Join: #{venue_url}" if @event.venue.present?
      end

      def location_line
        @event.venue.present? ? { "location" => @event.venue.name } : {}
      end

      def venue_url
        helpers = Rails.application.routes.url_helpers
        if (host = Rails.application.routes.default_url_options[:host].presence)
          helpers.room_url(@event.venue, host:)
        else
          helpers.room_path(@event.venue)
        end
      end

      def error_summary(error)
        "#{error.class.name.demodulize}: #{error.message}".truncate(250)
      end
  end
end
