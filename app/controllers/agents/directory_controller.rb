class Agents::DirectoryController < ApplicationController
  before_action :ensure_human

  # GET /agents (HTML). Every agent, active first then suspended,
  # name-sorted within each group. Signed-in humans only; bots 403
  # (Bearer agent tokens and legacy bot keys are denied by default).
  def index
    @agents = Agent.for_directory
  end

  private
    def ensure_human
      head :forbidden if Current.user.bot?
    end
end
