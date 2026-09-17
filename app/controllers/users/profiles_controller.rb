class Users::ProfilesController < ApplicationController
  before_action :set_user

  def show
    set_memberships
  end

  def update
    if @user.update(user_params)
      redirect_to user_profile_url, notice: update_notice
    else
      set_memberships
      render :show, status: :unprocessable_entity
    end
  end

  private
    def set_user
      @user = Current.user
    end

    def set_memberships
      @direct_memberships, @shared_memberships =
        Current.user.memberships.with_ordered_room.partition { |m| m.room.direct? }
    end

    def user_params
      params.require(:user).permit(:name, :avatar, :email_address, :password, :bio, :github_login, inbox_preferences: User::InboxPreferences::KEYS).compact
    end

    def update_notice
      params[:user][:avatar] ? "It may take up to 30 minutes to change everywhere." : "✓"
    end
end
