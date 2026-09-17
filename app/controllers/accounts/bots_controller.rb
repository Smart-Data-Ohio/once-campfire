class Accounts::BotsController < ApplicationController
  before_action :ensure_can_administer, only: %i[ index new create destroy ]
  before_action :set_bot, only: %i[ edit update destroy ]
  before_action :ensure_can_manage_bot, only: %i[ edit update ]
  before_action :set_agent, only: %i[ edit update ]

  def index
    @bots = User.active_bots.ordered.includes(agent: :owner)
  end

  def new
    @bot = User.active_bots.new
  end

  def create
    bot = User.create_bot! bot_params
    bot.create_agent!(kind: :workspace, owner: Current.user)
    redirect_to account_bots_url
  rescue ActiveRecord::RecordInvalid => error
    @bot = error.record
    render :new, status: :unprocessable_entity
  end

  def edit
  end

  def update
    @agent&.assign_attributes(agent_params)

    if @agent&.invalid?
      render :edit, status: :unprocessable_entity
    elsif @bot.update_bot(bot_params)
      @agent&.save!
      redirect_to account_bots_url
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @bot.deactivate
    redirect_to account_bots_url
  end

  private
    def set_bot
      @bot = User.active_bots.find(params[:id])
    end

    def ensure_can_manage_bot
      head :forbidden unless Current.user.administrator? || @bot.agent&.owner == Current.user
    end

    # A legacy bot without an agent row stays that way: reading or editing
    # its page must not silently convert it into an agent.
    def set_agent
      @agent = @bot.agent
    end

    def bot_params
      params.require(:user).permit(:name, :avatar, :webhook_url, :icon_name)
    end

    def agent_params
      params.permit(agent: %i[ provider runtime description ])[:agent] || {}
    end
end
