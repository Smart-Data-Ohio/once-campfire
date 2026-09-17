# Rooms with a standing stage huddle: a few members speak while everyone else
# listens. Hosts run the stage, speakers publish audio/video, and listeners
# can only subscribe. Membership works like Rooms::Voice, with explicit
# members chosen by an administrator or the creator, plus a per-member stage
# role. The room creator becomes the first host.
class Rooms::Stage < Room
  has_many :streams, foreign_key: :room_id, dependent: :destroy

  # The room's current live stream, if any. Queried fresh unless the caller
  # preloaded streams, in which case the preloaded records are read so list
  # pages can render the live dot without a query per room.
  def live_stream
    if association(:streams).loaded?
      streams.detect(&:live?)
    else
      streams.live.first
    end
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
