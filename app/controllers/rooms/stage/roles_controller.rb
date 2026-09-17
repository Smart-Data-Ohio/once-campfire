class Rooms::Stage::RolesController < ApplicationController
  include RoomScoped

  rescue_from ActiveRecord::RecordNotFound, with: -> { head :not_found }

  before_action :ensure_stage_room
  before_action :ensure_can_manage_stage

  STAGE_ROLES = %w[ listener speaker host ].freeze

  # Hosts and administrators change any member's stage role. The role change
  # revokes the member's huddle grants in the same transaction, and two
  # broadcasts deliver it: the shared roster goes to the room's stream, and a
  # personalized panel with a rejoin trigger goes to the affected member's own
  # rooms stream, so their browser rejoins with a fresh token for the new role.
  def update
    target = @room.memberships.find_by(id: params[:membership_id])
    return head :not_found unless target

    unless STAGE_ROLES.include?(params[:stage_role].to_s)
      return render plain: "Unknown stage role", status: :unprocessable_entity
    end

    begin
      target.change_stage_role!(params[:stage_role])
    rescue ActiveRecord::RecordInvalid => error
      return render plain: error.record.errors.full_messages.to_sentence, status: :unprocessable_entity
    end

    broadcast_roster
    broadcast_panel_to_member(target)
    respond_with_roster
  end

  private
    # Administrators manage through membership like everyone else: an
    # administrator who is not a member of the room gets the same 404 as any
    # other non-member from the room scoping above.
    def ensure_can_manage_stage
      head :forbidden unless @membership.host? || Current.user.administrator?
    end

    def ensure_stage_room
      head :not_found unless @room.stage?
    end

    def broadcast_roster
      broadcast_replace_to @room, :messages,
        target: [ @room, :stage_roster ],
        partial: "rooms/stage/roster",
        locals: { room: @room }
    end

    def broadcast_panel_to_member(target)
      broadcast_replace_to target.user, :rooms,
        target: [ @room, :stage_panel ],
        partial: "rooms/stage/panel_body",
        locals: { room: @room, membership: target.reload, rejoin: true }
    end

    def respond_with_roster
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.replace([ @room, :stage_roster ],
            partial: "rooms/stage/roster",
            locals: { room: @room })
        end
        format.html { redirect_to room_url(@room) }
      end
    end
end
