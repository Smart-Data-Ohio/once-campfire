class WorkThreadsController < ApplicationController
  def index
    @state = params[:state].to_s.in?(%w[all done]) ? params[:state].to_s : "open"
    @threads = visible_work_threads
    no_store_response!

    respond_to do |format|
      format.html
      format.json { render json: { threads: @threads.map { |thread| thread_payload(thread) } } }
    end
  end

  private
    def visible_work_threads
      scope = ChannelThread
        .work
        .for_room_member(Current.user)
        .includes(:room, :creator, :work_owner, :memberships)
        .order(updated_at: :desc, id: :desc)

      case @state
      when "done"
        scope.where(work_status: "done")
      when "all"
        scope
      else
        scope.where.not(work_status: "done")
      end
    end
end
