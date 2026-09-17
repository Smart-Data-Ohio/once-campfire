class Accounts::Bots::GithubConnectionsController < ApplicationController
  before_action :set_bot
  before_action :ensure_can_manage_bot

  # Links the agent's own fine-grained personal access token (for a GitHub
  # machine user dedicated to the agent) so approved write actions run as
  # the agent's GitHub identity — never the workspace token and never a
  # person's token. The pasted token is validated with GET /user before
  # anything is stored; it is never logged (filtered as :token) or
  # rendered back.
  def create
    token = params[:access_token].to_s.strip
    if token.blank?
      return redirect_to edit_account_bot_path(@bot), alert: "Paste a token to connect GitHub."
    end

    login = Github::WriteClient.authenticated_login(token)
    account = @bot.github_connected_account || @bot.build_github_connected_account
    account.assign_attributes(github_login: login, access_token: token, disconnected_reason: nil)
    account.save!

    redirect_to edit_account_bot_path(@bot), notice: "GitHub connected as #{login}."
  rescue Github::WriteClient::Unauthorized
    redirect_to edit_account_bot_path(@bot), alert: "GitHub rejected that token. Check it and try again."
  rescue Github::WriteClient::Error
    redirect_to edit_account_bot_path(@bot), alert: "Could not reach GitHub. Try again."
  end

  def destroy
    @bot.github_connected_account&.destroy!
    redirect_to edit_account_bot_path(@bot), notice: "GitHub disconnected."
  end

  private
    def set_bot
      @bot = User.active_bots.find(params[:bot_id])
    end

    def ensure_can_manage_bot
      head :forbidden unless Current.user.administrator? || @bot.agent&.owner == Current.user
    end
end
