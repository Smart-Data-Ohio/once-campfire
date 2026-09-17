# Shared Drive-attachment handling for room and thread messages. Only file
# ids are stored; names resolve at view time with the viewer's own Google
# credentials (see docs/google-drive.md#attachments), so the Drive scope is
# not required to submit an id.
module Messages::DriveAttachable
  extend ActiveSupport::Concern

  private
    # True when the form submitted the Drive attachment set at all. The edit
    # form always sends the key (with a blank sentinel so "remove all" is
    # expressible); the composer only sends it when the strip holds chips.
    # Absent means "leave the stored set alone".
    def drive_file_ids_key_present?
      params[:message].is_a?(ActionController::Parameters) && params[:message].key?(:drive_file_ids)
    end

    # nil when the key is not an array (a scalar would otherwise permit to an
    # empty set and silently remove everything).
    def normalized_drive_file_ids
      raw = params[:message][:drive_file_ids]
      return nil unless raw.is_a?(Array)

      raw.map { |id| id.to_s.strip }.reject(&:blank?).uniq
    end

    # Replaces the message's stored Drive set with the submitted ids, in
    # memory so the message and its attachments save in one transaction. An
    # invalid id raises before anything is written.
    def apply_drive_file_ids!(message)
      ids = normalized_drive_file_ids

      if ids.nil? || ids.reject { |id| Google::DriveLink.valid_id?(id) }.any?
        message.errors.add :drive_attachments, "includes an invalid file id"
        raise ActiveRecord::RecordInvalid, message
      end

      current = message.drive_attachments.to_a
      current.each do |attachment|
        attachment.mark_for_destruction unless ids.include?(attachment.file_id)
      end
      (ids - current.map(&:file_id)).each do |file_id|
        message.drive_attachments.build(file_id:)
      end
    end

    # The submitted id set for a message that another object creates (thread
    # posts go through ChannelThread#post_message!, which needs plain ids
    # rather than an unsaved message to build on). nil when the key is
    # absent; raises RecordInvalid exactly like apply_drive_file_ids!.
    def validated_drive_file_ids!
      return nil unless drive_file_ids_key_present?

      probe = Message.new
      apply_drive_file_ids!(probe)
      probe.drive_attachments.map(&:file_id)
    end
end
