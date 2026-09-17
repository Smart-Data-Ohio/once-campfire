module Github
  # Links a member's own fine-grained personal access token so PR write
  # actions run as their GitHub user. The pasted token is validated with
  # GET /user before anything is stored; it is never logged (filtered as
  # :token) or rendered back.
  class ConnectionsController < ApplicationController
    def create
      token = params[:access_token].to_s.strip
      if token.blank?
        return redirect_to user_profile_path, alert: "Paste a token to connect GitHub."
      end

      login = WriteClient.authenticated_login(token)
      account = Current.user.github_connected_account || Current.user.build_github_connected_account
      account.assign_attributes(github_login: login, access_token: token, disconnected_reason: nil)
      account.save!

      redirect_to user_profile_path, notice: link_notice(login)
    rescue WriteClient::Unauthorized
      redirect_to user_profile_path, alert: "GitHub rejected that token. Check it and try again."
    rescue WriteClient::Error
      redirect_to user_profile_path, alert: "Could not reach GitHub. Try again."
    end

    def destroy
      Current.user.github_connected_account&.destroy!
      redirect_to user_profile_path, notice: "GitHub disconnected."
    end

    private
      def link_notice(login)
        if Current.user.github_login.blank?
          if Current.user.update(github_login: login)
            "GitHub connected as #{login}."
          else
            "GitHub connected as #{login}. That username is linked to another member, so your profile username was left blank."
          end
        elsif Current.user.github_login != login.to_s.downcase
          "GitHub connected as #{login}, which differs from your profile username (#{Current.user.github_login}). Review requests still use the profile username."
        else
          "GitHub connected as #{login}."
        end
      end
  end
end
