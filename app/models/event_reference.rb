class EventReference < ApplicationRecord
  belongs_to :message
  belongs_to :event

  validates :event_id, uniqueness: { scope: :message_id }
end
