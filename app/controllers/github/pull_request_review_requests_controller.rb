# Requests a review from one or more GitHub users on the PR, as the
# member's own GitHub user through the member's linked token. GitHub
# treats a request for someone who already reviewed as a re-request, so
# this one control covers both. The thread itself gets no local message;
# the review_requested webhook refreshes the card and posts through
# subscriptions.
class Github::PullRequestReviewRequestsController < ApplicationController
  include GithubWriteAction

  LOGIN_PATTERN = /\A[a-z\d](?:[a-z\d]|-(?=[a-z\d])){0,38}\z/i
  MAX_REVIEWERS = 15
  INVALID_REVIEWERS_MESSAGE = "Enter GitHub usernames separated by commas.".freeze

  def create
    submitted = params[:reviewers].to_s
    logins = normalize_logins(submitted)

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

  private
    # Splits on commas or whitespace, strips one leading @, downcases for
    # comparison, and dedupes. Returns nil when any login is invalid or
    # there are more than MAX_REVIEWERS unique logins.
    def normalize_logins(submitted)
      logins = submitted.split(/[\s,]+/).reject(&:empty?).map { |token| token.sub(/\A@/, "").downcase }
      return nil if logins.any? { |login| !LOGIN_PATTERN.match?(login) }

      logins = logins.uniq
      return nil if logins.size > MAX_REVIEWERS

      logins
    end
end
