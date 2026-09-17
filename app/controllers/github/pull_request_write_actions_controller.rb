# Serves the personalized write-actions frame for a PR thread: the comment
# composer and review buttons for members with a usable linked token, the
# connect prompt for everyone else. Loaded per viewer because the thread
# header's live broadcasts render without a current user.
class Github::PullRequestWriteActionsController < ApplicationController
  include GithubWriteAction

  def show
    render partial: "github/pull_requests/write_actions",
      locals: { thread: @thread, pull_request: @pull_request, notice: nil, alert: nil }
  end
end
