# Submits an approve or request-changes review on the PR as the member's
# own GitHub user, through the member's linked token. The thread itself
# gets no local message; the review round-trips through the existing
# pull_request_review webhook path and the bot's echo post stays as the
# confirmation.
class Github::PullRequestReviewsController < ApplicationController
  include GithubWriteAction

  REVIEW_EVENTS = %w[ APPROVE REQUEST_CHANGES ].freeze

  def create
    event = params[:event].to_s
    unless REVIEW_EVENTS.include?(event)
      return render_write_result(alert: "Choose Approve or Request changes.", status: :unprocessable_content)
    end

    body = params[:body].to_s.strip
    if event == "REQUEST_CHANGES" && body.blank?
      return render_write_result(alert: "Add a note describing the requested changes.", status: :unprocessable_content)
    end

    account = github_account
    unless account&.usable?
      return render_write_result(status: :unprocessable_content)
    end

    write_client_for(account).create_review(@pull_request, event: event, body: body.presence)
    render_write_result(notice: review_notice(event, account))
  rescue Github::WriteClient::Unauthorized
    account.mark_disconnected!("GitHub rejected the linked token (401)")
    render_write_result(alert: "GitHub rejected your token. Reconnect to post.", status: :unprocessable_content)
  rescue Github::WriteClient::Refused, Github::WriteClient::Error => error
    render_write_result(alert: error.message, status: :unprocessable_content)
  end

  private
    def review_notice(event, account)
      if event == "APPROVE"
        "Approved on GitHub as @#{account.github_login}."
      else
        "Requested changes on GitHub as @#{account.github_login}."
      end
    end
end
