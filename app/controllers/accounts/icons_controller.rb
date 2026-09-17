class Accounts::IconsController < ApplicationController
  before_action :ensure_can_administer

  def index
    @workspace_icons = WorkspaceIcon.ordered.with_attached_image.includes(:creator)
    @workspace_icon = WorkspaceIcon.new
  end

  def create
    @workspace_icon = WorkspaceIcon.new(workspace_icon_params)
    @workspace_icon.creator = Current.user

    if save_icon
      redirect_to account_icons_url, notice: "Icon added"
    else
      @workspace_icons = WorkspaceIcon.ordered.with_attached_image.includes(:creator)
      render :index, status: :unprocessable_entity
    end
  end

  def destroy
    WorkspaceIcon.find(params[:id]).destroy
    redirect_to account_icons_url, notice: "Icon deleted"
  end

  private
    # A concurrent upload of the same name slips past the uniqueness
    # validation and hits the unique index; report it like any other
    # validation failure instead of a 500.
    def save_icon
      @workspace_icon.save
    rescue ActiveRecord::RecordNotUnique
      @workspace_icon.errors.add(:name, :taken)
      false
    end

    def workspace_icon_params
      params.require(:workspace_icon).permit(:name, :title, :image)
    end
end
