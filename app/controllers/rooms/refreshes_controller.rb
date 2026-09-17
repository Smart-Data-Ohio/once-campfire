class Rooms::RefreshesController < ApplicationController
  include RoomScoped

  # A refresh fired by a reconnect after the member was removed is routine,
  # not an error worth raising; the room UI is torn down by the broadcast.
  rescue_from ActiveRecord::RecordNotFound do
    head :not_found
  end

  before_action :set_last_updated_at

  def show
    @new_messages = @room.root_messages.with_rendering_details.page_created_since(@last_updated_at)
    @updated_messages = @room.root_messages.without(@new_messages).with_rendering_details.page_updated_since(@last_updated_at)
  end

  private
    def set_last_updated_at
      @last_updated_at = Time.at(0, params[:since].to_i, :millisecond)
    end
end
