# Requests a review from one or more GitHub users on the PR, as the
# member's own GitHub user through the member's linked token. GitHub
# treats a request for someone who already reviewed as a re-request, so
# this one control covers both. The thread itself gets no local message;
# the review_requested webhook refreshes the card and posts through
# subscriptions.
class Github::PullRequestReviewRequestsController < ApplicationController
  include GithubWriteAction

  INVALID_REVIEWERS_MESSAGE = Github::ReviewLogins::INVALID_MESSAGE

  def create
    submitted = params[:reviewers].to_s
    logins = Github::ReviewLogins.normalize(submitted)

    if logins.blank?
      return render_write_result(alert: INVALID_REVIEWERS_MESSAGE, status: :unprocessable_content, reviewers_body: submitted)
    end

    account = github_account
    unless account&.usable?
      return render_write_result(status: :unprocessable_content)
    end

    write_client_for(account).request_reviewers(@pull_request, logins: logins)
    render_write_result(notice: "Requested review from #{logins.map { |login| "@#{login}" }.join(", ")} on GitHub as @#{account.github_login}.")
  rescue Github::WriteClient::Unauthorized
    account.mark_disconnected!("GitHub rejected the linked token (401)")
    render_write_result(alert: "GitHub rejected your token. Reconnect to post.", status: :unprocessable_content)
  rescue Github::WriteClient::Refused, Github::WriteClient::Error => error
    render_write_result(alert: error.message, status: :unprocessable_content, reviewers_body: submitted)
  end
end
