# Rooms with a standing stage huddle: a few members speak while everyone else
# listens. Hosts run the stage, speakers publish audio/video, and listeners
# can only subscribe. Membership works like Rooms::Voice, with explicit
# members chosen by an administrator or the creator, plus a per-member stage
# role. The room creator becomes the first host.
class Rooms::Stage < Room
  has_many :streams, foreign_key: :room_id, dependent: :destroy

  # The room's current live stream, if any. Queried fresh every time: streams
  # start and end within a request, so a memoized value would go stale.
  def live_stream
    streams.live.first
  end

  class << self
    def create_for(attributes, users:)
      super.tap do |room|
        room.memberships.where(stage_role: nil).update_all(stage_role: :listener)
        room.memberships.find_or_create_by!(user: room.creator).update!(stage_role: :host)
      end
    end
  end
end
