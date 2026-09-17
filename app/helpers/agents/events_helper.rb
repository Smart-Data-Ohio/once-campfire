module Agents::EventsHelper
  # True when the event's message content may be shown on the ledger page:
  # the message still exists, the agent's user is currently a member of its
  # room with an active read_messages grant covering it (or legacy
  # capabilities), and the viewer is an administrator or a current member of
  # that room. Event metadata always renders; content renders only here.
  def agent_event_content_visible?(agent, event, viewer)
    message = event.message
    return false if message.nil?

    room = message.room
    return false unless Membership.exists?(user_id: agent.user_id, room_id: room.id)
    return false unless agent.can?(:read_messages, room)

    viewer.administrator? || Membership.exists?(user_id: viewer.id, room_id: room.id)
  end
end
