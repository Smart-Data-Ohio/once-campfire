module Event::ReferenceSync
  # Event URLs in message text: /rooms/:room_id/events/:id, absolute or
  # relative, on any host, with any trailing path, query, or fragment.
  PATTERN = %r{/rooms/\d+/events/(?<id>\d+)\b}

  class << self
    # Reconciles a message's event references with the event URLs its
    # content currently contains. Idempotent: re-running with unchanged
    # content changes nothing. Links to events that do not exist create
    # nothing.
    def call(message)
      events = ::Event.where(id: extract_event_ids(reference_text(message)))

      message.event_references.where.not(event_id: events.select(:id)).delete_all

      events.each do |event|
        message.event_references.find_or_create_by!(event: event)
      end
    rescue ActiveRecord::RecordNotUnique
      retry
    end

    # Unique event ids referenced by the given text.
    def extract_event_ids(text)
      return [] if text.blank?

      text.to_s.scan(PATTERN).flatten.map(&:to_i).uniq
    end

    private
      def reference_text(message)
        [ message.markdown_source, message.plain_text_body ].compact_blank.join("\n")
      end
  end
end
