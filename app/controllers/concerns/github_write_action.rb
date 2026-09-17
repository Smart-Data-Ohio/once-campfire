# Shared scoping for PR write actions from a PR thread: room membership
# (RoomScoped 404s non-members) plus the room's discussion-thread mapping
# for the PR, which is also the Turbo Frame the responses replace.
module GithubWriteAction
  extend ActiveSupport::Concern

  included do
    include RoomScoped
    before_action :set_pull_request_and_thread
  end

  private
    def set_pull_request_and_thread
      @pull_request = Github::PullRequest.find(params[:pull_request_id] || params[:id])
      @thread = Github::PullRequestThread.find_by!(pull_request: @pull_request, room: @room).channel_thread
    end

    def github_account
      Current.user.github_connected_account
    end

    def write_client_for(account)
      Github::WriteClient.new(token: account.access_token)
    end

    # Re-renders the thread's write-actions frame: fresh forms plus an
    # inline confirmation or error. The frame submission takes the HTML
    # branch; Turbo Stream requests take the stream branch.
    def render_write_result(notice: nil, alert: nil, status: :ok)
      locals = { thread: @thread, pull_request: @pull_request, notice: notice, alert: alert }

      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.replace(
            ActionView::RecordIdentifier.dom_id(@thread, :github_write_actions),
            partial: "github/pull_requests/write_actions", locals: locals
          ), status: status
        end
        format.html { render partial: "github/pull_requests/write_actions", locals: locals, status: status }
      end
    end
end
