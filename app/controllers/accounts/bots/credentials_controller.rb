class Accounts::Bots::CredentialsController < ApplicationController
  before_action :ensure_can_administer
  before_action :set_bot
  before_action :set_agent

  def index
    @credentials = @agent.agent_credentials.order(created_at: :desc)
    @credential = AgentCredential.new
  end

  def create
    @credential, @plain_secret = AgentCredential.create_with_secret!(
      agent: @agent,
      name: credential_params[:name],
      created_by: Current.user,
      expires_at: credential_params[:expires_at].presence
    )

    render :show, status: :created
  rescue ActiveRecord::RecordInvalid => error
    @credential = error.record
    @credentials = @agent.agent_credentials.order(created_at: :desc)
    render :index, status: :unprocessable_entity
  end

  def destroy
    @agent.agent_credentials.find(params[:id]).revoke!
    redirect_to account_bot_credentials_url(@bot)
  end

  private
    def set_bot
      @bot = User.active_bots.find(params[:bot_id])
    end

    def set_agent
      @agent = @bot.agent || @bot.create_agent!(kind: :workspace, owner: Current.user)
    end

    def credential_params
      params.require(:agent_credential).permit(:name, :expires_at)
    end
end
