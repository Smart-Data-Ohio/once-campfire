class Huddle::DeleteRoomJob < ApplicationJob
  retry_on Huddle::ServerError, wait: :polynomially_longer, attempts: 10

  def perform(room_name)
    return unless Huddle.configured?

    Huddle::RoomService.new.delete_room(room_name: room_name)
  end
end
