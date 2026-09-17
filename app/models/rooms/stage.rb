# Rooms with a standing stage huddle: a few members speak while everyone else
# listens. Hosts run the stage, speakers publish audio/video, and listeners
# can only subscribe. Membership works like Rooms::Voice, with explicit
# members chosen by an administrator or the creator, plus a per-member stage
# role. The room creator becomes the first host.
class Rooms::Stage < Room
  has_many :streams, foreign_key: :room_id, dependent: :destroy
  has_many :live_streams, -> { live }, class_name: "Stream", foreign_key: :room_id

  # The room's current live stream, if any. Queried fresh unless the caller
  # preloaded `live_streams` (at most one row per room), in which case the
  # preloaded record is read so list pages render the live dot without a
  # query per room. Ended rows are history and are never loaded for this.
  def live_stream
    if association(:live_streams).loaded?
      live_streams.first
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
