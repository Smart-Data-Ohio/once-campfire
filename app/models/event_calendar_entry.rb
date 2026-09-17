# The Google Calendar copy of one event for one member. Each connected
# member gets their own private copy on their primary calendar.
class EventCalendarEntry < ApplicationRecord
  belongs_to :event
  belongs_to :user

  validates :google_event_id, presence: true
  validates :user_id, uniqueness: { scope: :event_id }
end
