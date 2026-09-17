module Messages
  class Forwarder
    MAX_DESTINATIONS = 5
    Result = Data.define(:message, :room, :thread)

    class InvalidDestination < StandardError; end
    class TooManyDestinations < StandardError; end

    def self.call(source:, destinations:, note: nil, creator: Current.user)
      new(source:, destinations:, note:, creator:).call
    end

    def initialize(source:, destinations:, note:, creator:)
      @source = source
      @destinations = destinations
      @note = note.presence
      @creator = creator
      @copied_blobs = []
    end

    def call
      normalized_destinations = normalize_destinations

      Message.transaction(requires_new: true) do
        normalized_destinations.map { |destination| create_forward!(destination) }
      end
    rescue StandardError
      purge_copied_blobs
      raise
    end

    private
      attr_reader :source, :creator, :note

      def normalize_destinations
        raw_destinations = Array(@destinations).map { |destination| destination.to_h.with_indifferent_access }
        if raw_destinations.empty? || raw_destinations.length > MAX_DESTINATIONS
          raise TooManyDestinations, "Choose between 1 and #{MAX_DESTINATIONS} destinations"
        end

        normalized = raw_destinations.map do |destination|
          room_id = destination[:room_id].presence
          raise InvalidDestination, "A destination room is required" if room_id.blank?

          room = creator.rooms.find_by(id: room_id)
          raise InvalidDestination, "You cannot forward to that room" unless room

          thread = if destination[:thread_id].present?
            room.channel_threads.find_by(id: destination[:thread_id]).tap do |candidate|
              raise InvalidDestination, "That thread is unavailable" unless candidate
              raise InvalidDestination, "Direct rooms cannot contain threads" if room.direct?
              raise InvalidDestination, "That thread is locked" if candidate.locked?
            end
          end

          [ room, thread ]
        end

        if normalized.map { |room, thread| [ room.id, thread&.id ] }.uniq.length != normalized.length
          raise InvalidDestination, "Destinations must be unique"
        end

        normalized
      end

      def create_forward!((room, thread))
        lock_current_parent_membership!(room)

        if thread
          thread.with_lock do
            thread.reload
            raise InvalidDestination, "That thread is locked" if thread.locked?

            create_thread_forward!(room, thread)
          end
        else
          create_root_forward!(room)
        end
      end

      def create_thread_forward!(room, thread)
        ThreadMembership.join!(thread, creator)
        thread.update!(closed_at: nil, last_activity_at: Time.current)
        message = build_forward(room:, thread:)
        save_forward!(message)
        Result.new(message:, room:, thread:)
      end

      def create_root_forward!(room)
        message = build_forward(room:, thread: nil)
        save_forward!(message)
        Result.new(message:, room:, thread: nil)
      end

      def build_forward(room:, thread:)
        Message.new(
          room:,
          thread:,
          creator:,
          client_message_id: Random.uuid,
          body: snapshot_body,
          forwarded_from_message: source,
          forwarded_at: Time.current,
          forward_note: note
        ).tap do |message|
          copy_attachment_to(source, message)
          copy_drive_attachments_to(source, message)
        end
      end

      # Store a private copy of the rendered body, rather than source markdown
      # or flattened text. That keeps formatting stable through later source
      # edits/deletion and cannot re-resolve source mentions in the destination.
      def snapshot_body
        source_html = source.body.body.to_html
        return source_html if source.forward_note.blank?

        inherited_note = ERB::Util.html_escape(source.forward_note).gsub("\n", "<br>")
        "<p>#{inherited_note}</p>#{source_html}"
      end

      def save_forward!(message)
        message.save!
        message.process_attachment if message.attachment.attached?
      end

      def lock_current_parent_membership!(room)
        Membership.lock.find_by!(room:, user: creator)
      rescue ActiveRecord::RecordNotFound
        raise InvalidDestination, "You cannot forward to that room"
      end

      # Active Storage can defer an attachment upload until after Blob#open has
      # closed its IO. Upload a new blob while the tempfile is open, then attach
      # that blob to the new message. Files made before a later destination
      # fails are explicitly removed in the outer rescue.
      def copy_attachment_to(source, destination)
        return unless source.attachment.attached?

        source.attachment.blob.open do |io|
          Tempfile.create([ "campfire-forward-", source.attachment.filename.to_s ]) do |copy|
            IO.copy_stream(io, copy)
            copy.rewind
            blob = ActiveStorage::Blob.create_and_upload!(
              io: copy,
              filename: source.attachment.filename.to_s,
              content_type: source.attachment.content_type,
              identify: false,
              metadata: source.attachment.blob.metadata
            )
            @copied_blobs << blob
            destination.attachment.attach(blob)
          end
        end
      end

      # Ids only, never names: each viewer resolves the file with their own
      # Google credentials, exactly like the source message's attachments.
      def copy_drive_attachments_to(source, destination)
        source.drive_attachments.each do |attachment|
          destination.drive_attachments.build(file_id: attachment.file_id)
        end
      end

      def purge_copied_blobs
        @copied_blobs.each do |blob|
          # Blob#delete also removes generated image variants.
          blob.delete
          blob.destroy if blob.persisted?
        rescue StandardError => error
          Rails.logger.warn "Could not remove failed forward attachment #{blob.key}: #{error.class}"
        end
      end
  end
end
