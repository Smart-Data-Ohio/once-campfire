class Event::ReminderPushJob < ApplicationJob
  def perform(event)
    Event::ReminderPusher.new(event:).push
  end
end
