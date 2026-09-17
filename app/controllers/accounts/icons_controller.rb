class Accounts::IconsController < ApplicationController
  before_action :ensure_can_administer

  def index
    @workspace_icons = WorkspaceIcon.ordered.with_attached_image
    @workspace_icon = WorkspaceIcon.new
  end

  def create
    @workspace_icon = WorkspaceIcon.new(workspace_icon_params)
    @workspace_icon.creator = Current.user

    if @workspace_icon.save
      redirect_to account_icons_url, notice: "Icon added"
    else
      @workspace_icons = WorkspaceIcon.ordered.with_attached_image
      render :index, status: :unprocessable_entity
    end
  end

  def destroy
    WorkspaceIcon.find(params[:id]).destroy
    redirect_to account_icons_url, notice: "Icon deleted"
  end

  private
    def workspace_icon_params
      params.require(:workspace_icon).permit(:name, :title, :image)
    end
end
