module Event::ChannelTimeline
  extend ActiveSupport::Concern

  private
    # One root message in the event's room, posted as the organizer through
    # the same path bot posts use. A repeating series announces once, for
    # the head; materialized occurrences never announce. Edits and
    # cancellations post nothing; the card carries them. No inbox items change.
    def announce_in_channel
      return if series_id.present? && series_id != id

      room.root_messages.create_with_attachment!(
        creator: organizer, markdown_source: "Scheduled an event: #{title}\n#{event_url}"
      ).tap(&:broadcast_create)
    end

    # Replaces each referencing message's cards over the room messages
    # stream, like Github::PullRequest#broadcast_card_updates. The card body
    # is viewer-independent; the lazy attendance frame inside reloads with
    # the replaced card, so each viewer's own response stays fresh. There is
    # deliberately no per-viewer broadcast.
    def broadcast_event_card_updates
      referencing_messages.find_each do |message|
        Turbo::StreamsChannel.broadcast_replace_to(
          message.message_stream_target, :messages,
          target: ActionView::RecordIdentifier.dom_id(message, :event_cards),
          partial: "rooms/events/cards",
          locals: { message: message },
          attributes: { maintain_scroll: true }
        )
      end
    end

    # Same host source Calendar::EntrySync#event_url uses, so the announcement
    # links the event page absolutely in deployed environments and relatively
    # wherever no host is configured (tests included).
    def event_url
      helpers = Rails.application.routes.url_helpers
      if (host = Rails.application.routes.default_url_options[:host].presence)
        helpers.room_event_url(room, self, host:)
      else
        helpers.room_event_path(room, self)
      end
    end
end
