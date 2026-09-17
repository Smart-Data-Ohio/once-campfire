class Users::HuddlePresenceController < ApplicationController
  prepend_before_action :prevent_caching
  before_action :ensure_huddles_configured
  before_action :ensure_human_user
  before_action :ensure_active_user

  # Every room of the current user with at least one participant in the
  # call, for the sidebar's aggregate presence poll: one request per
  # browser instead of one per row.
  def show
    grants = HuddleGrant.active.in_call
      .where(room_id: Current.user.memberships.select(:room_id))
      .includes(:user)

    render json: grants.group_by(&:room_id).filter_map { |room_id, room_grants|
      participants = room_grants.filter_map(&:user).uniq.sort_by { |user| user.name.downcase }
      next if participants.empty?

      {
        room_id: room_id,
        participants: participants.map { |user|
          { id: user.id, name: user.name, avatar_url: helpers.fresh_user_avatar_url(user) }
        }
      }
    }
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

    def render_error(message, status)
      render json: { error: message }, status: status
    end

    def prevent_caching
      response.headers["Cache-Control"] = "no-store"
    end
end
