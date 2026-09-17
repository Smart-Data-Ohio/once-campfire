# Serves the per-viewer card frame for a PR referenced in the room: the card
# partial when the viewer may see it, an empty frame otherwise. Cards for
# private (or still unknown) repositories load through here — lazily, one
# frame per card — because the message HTML is fragment-cached across
# viewers and the thread header's live broadcasts render without a
# current user. RoomScoped 404s non-members; the PR must be referenced in
# the room through the given message or thread mapping.
class Rooms::Github::PullRequestCardsController < ApplicationController
  include RoomScoped

  def show
    @pull_request = Github::PullRequest.find(params[:id])

    if params[:message_id].present?
      @message = @room.messages.find(params[:message_id])
      raise ActiveRecord::RecordNotFound unless @pull_request.pull_request_references.exists?(message_id: @message.id)
      @frame_id = helpers.github_pr_card_frame_id(@pull_request, message_id: @message.id)
    elsif params[:thread_id].present?
      @thread = @room.channel_threads.find(params[:thread_id])
      raise ActiveRecord::RecordNotFound unless Github::PullRequestThread.exists?(
        pull_request: @pull_request, room: @room, channel_thread: @thread)
      @frame_id = helpers.github_pr_card_frame_id(@pull_request, thread_id: @thread.id)
    else
      raise ActiveRecord::RecordNotFound
    end

    @visible = helpers.github_pr_visible_to?(@pull_request, Current.user)

    render layout: false
  end
end
