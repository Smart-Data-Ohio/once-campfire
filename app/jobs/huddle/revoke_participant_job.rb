class Huddle::RevokeParticipantJob < ApplicationJob
  retry_on Huddle::ServerError, wait: :polynomially_longer, attempts: 10

  def perform(room_name, identity)
    return unless Huddle.configured?

    Huddle::RoomService.new.remove_participant(room_name: room_name, identity: identity)
  end
end
