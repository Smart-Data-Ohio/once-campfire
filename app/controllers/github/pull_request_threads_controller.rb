# The Discuss control on a PR card posts here. One thread per PR per room:
# an existing mapping redirects to its thread, otherwise a thread is
# created with the card's message as its parent and the mapping is
# recorded. RoomScoped gives the same permissions as thread creation —
# any room member — and 404s non-members.
class Github::PullRequestThreadsController < ApplicationController
  include RoomScoped

  def create
    pull_request = Github::PullRequest.find(params[:pull_request_id])
    parent_message = @room.root_messages.find(params[:message_id])
    raise ActiveRecord::RecordNotFound unless pull_request.pull_request_references.exists?(message_id: parent_message.id)

    if (existing = Github::PullRequestThread.find_by(pull_request: pull_request, room: @room))
      redirect_to room_thread_path(@room, existing.channel_thread), status: :see_other
      return
    end

    thread = create_thread!(parent_message)
    mapping = Github::PullRequestThread.create_or_reuse!(pull_request: pull_request, room: @room, channel_thread: thread)

    if mapping.channel_thread_id == thread.id
      Github::FetchPullRequestJob.perform_later(pull_request)
      redirect_to room_thread_path(@room, thread), status: :see_other
    else
      # Lost an insert race: the winner's thread stands, ours was never
      # mapped and goes away so no orphaned empty thread is left behind.
      thread.destroy!
      redirect_to room_thread_path(@room, mapping.channel_thread), status: :see_other
    end
  rescue ActiveRecord::RecordInvalid => error
    render_error error.record.errors.full_messages.to_sentence
  end

  private
    # Same creation path ChannelThreadsController#create takes: a thread
    # owned by the current member with the card's message as parent, joined
    # immediately. Direct rooms stay threadless through the model validation.
    def create_thread!(parent_message)
      ChannelThread.transaction do
        ChannelThread.create!(room: @room, creator: Current.user, parent_message: parent_message).tap do |thread|
          ThreadMembership.join!(thread, Current.user)
        end
      end
    end

    def render_error(message, status: :unprocessable_content)
      respond_to do |format|
        format.html { head status }
        format.json { render json: { error: message }, status: status }
        format.any { head status }
      end
    end
end
