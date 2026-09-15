class Rooms::HuddlesController < ApplicationController
  prepend_before_action :prevent_caching
  before_action :ensure_huddles_configured
  before_action :ensure_human_user
  before_action :ensure_active_user
  before_action :set_room
  before_action :ensure_one_to_one_direct_room

  def show
    render json: { room: room_json }
  end

  def create
    huddle = Huddle.new(room: @room, user: Current.user, session: Current.session, membership: @membership)

    render json: {
      url: huddle.url,
      token: huddle.token,
      room: room_json,
      identity: huddle.identity,
      grant_id: huddle.grant_id
    }
  rescue HuddleGrant::Ineligible
    render_error "Room not found or inaccessible", :not_found
  end

  private
    def request_authentication
      render_error "Authentication required", :unauthorized
    end

    def deny_bots
      render_error "Bots cannot join huddles", :forbidden if authenticated_by.bot_key?
    end

    def ensure_huddles_configured
      render_error "Huddles are not configured", :service_unavailable unless Huddle.configured?
    end

    def ensure_human_user
      render_error "Bots cannot join huddles", :forbidden if Current.user&.bot?
    end

    def ensure_active_user
      render_error "User cannot join huddles", :forbidden unless Current.user&.active?
    end

    def set_room
      @membership = Current.user.memberships.find_by(room_id: params[:room_id])
      @room = @membership&.room
      render_error "Room not found or inaccessible", :not_found unless @membership && @room
    end

    def ensure_one_to_one_direct_room
      return unless @room.direct? && @room.users.count != 2

      render_error "Huddles are only available in one-to-one direct messages", :unprocessable_entity
    end

    def room_json
      { id: @room.id, name: helpers.room_display_name(@room) }
    end

    def render_error(message, status)
      render json: { error: message }, status: status
    end

    def prevent_caching
      response.headers["Cache-Control"] = "no-store"
    end
end
