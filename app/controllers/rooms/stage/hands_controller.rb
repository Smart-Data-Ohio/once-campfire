class Rooms::Stage::HandsController < ApplicationController
  include RoomScoped

  rescue_from ActiveRecord::RecordNotFound, with: -> { head :not_found }

  before_action :ensure_stage_room

  # Listeners raise their own hand. Speakers and hosts have no hand to raise.
  def create
    unless @membership.listener?
      return render plain: "Only listeners can raise a hand", status: :unprocessable_entity
    end

    @membership.raise_hand!
    broadcast_roster
    respond_with_controls
  end

  # Clears a raised hand: your own, or — with a membership_id parameter —
  # another member's, for hosts and administrators. Clearing a hand that was
  # never raised succeeds without doing anything.
  def destroy
    target = target_membership
    return if performed?

    target.lower_hand!
    broadcast_roster
    respond_with_controls
  end

  private
    def target_membership
      if params[:membership_id].present?
        unless @membership.host? || Current.user.administrator?
          render plain: "Only hosts can lower another member's hand", status: :forbidden
          return nil
        end

        target = @room.memberships.find_by(id: params[:membership_id])
        head :not_found unless target
        target
      else
        @membership
      end
    end

    def ensure_stage_room
      head :not_found unless @room.stage?
    end

    # Host action forms render only for viewers who may use them, so each
    # member gets their own roster on their own stream. Stage rooms are
    # small; a loop is fine.
    def broadcast_roster
      @room.memberships.includes(:user).each do |member|
        broadcast_replace_to member.user, :rooms,
          target: [ @room, :stage_roster ],
          partial: "rooms/stage/roster",
          locals: { room: @room, viewer: member }
      end
    end

    def respond_with_controls
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.replace([ @room, :stage_controls ],
            partial: "rooms/stage/controls",
            locals: { room: @room, membership: @membership })
        end
        format.html { redirect_to room_url(@room) }
      end
    end
end
