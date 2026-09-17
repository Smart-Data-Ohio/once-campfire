# A Google Drive file attached to a message. Stores only the file id: the
# name, type, and every other metadata field resolve at view time with
# the viewer's own Google credentials (see docs/google-drive.md), so an
# attachment never leaks a private document's metadata to members who
# cannot open it.
class DriveAttachment < ApplicationRecord
  MAX_PER_MESSAGE = 10

  belongs_to :message, touch: true

  validates :file_id, presence: true, uniqueness: { scope: :message_id }
  validate :supported_file_id_format

  # The one Drive URL shape attachments use. Matches Google::DriveLink and
  # the drive-link Stimulus controller, which upgrades the anchor for
  # viewers who can open the file.
  def url
    "https://drive.google.com/open?id=#{file_id}"
  end

  private
    def supported_file_id_format
      errors.add(:file_id, "is invalid") unless Google::DriveLink.valid_id?(file_id)
    end
end
