# Posts a comment on the PR as the member's own GitHub user, through the
# member's linked token. The thread itself gets no local message; the
# comment round-trips through the issue_comment webhook, which refreshes
# the card.
class Github::PullRequestCommentsController < ApplicationController
  include GithubWriteAction

  def create
    body = params[:body].to_s.strip
    if body.blank?
      return render_write_result(alert: "Write a comment first.", status: :unprocessable_content)
    end

    account = github_account
    unless account&.usable?
      return render_write_result(status: :unprocessable_content)
    end

    write_client_for(account).create_issue_comment(@pull_request, body: body)
    render_write_result(notice: "Comment posted on GitHub as @#{account.github_login}.")
  rescue Github::WriteClient::Unauthorized
    account.mark_disconnected!("GitHub rejected the linked token (401)")
    render_write_result(alert: "GitHub rejected your token. Reconnect to post.", status: :unprocessable_content)
  rescue Github::WriteClient::Refused, Github::WriteClient::Error => error
    render_write_result(alert: error.message, status: :unprocessable_content, comment_body: body)
  end
end
