module Github::PullRequestsHelper
  # PRs referenced by a message, oldest reference first. Rendering a stale
  # card re-enqueues a fetch so rarely viewed cards converge without a
  # webhook; the fetch updates fetched_at, so this cannot loop.
  def github_pr_cards_for(message)
    pull_requests = message.github_pull_requests.order(:owner, :repo, :number).to_a

    pull_requests.each do |pull_request|
      Github::FetchPullRequestJob.perform_later(pull_request) if pull_request.stale?
    end

    pull_requests
  end

  def github_pr_state_label(pull_request)
    case pull_request.state
    when "merged" then "Merged"
    when "closed" then "Closed"
    when "draft" then "Draft"
    else "Open"
    end
  end

  def github_pr_review_label(pull_request)
    case pull_request.review_decision
    when "approved" then "Approved"
    when "changes_requested" then "Changes requested"
    when "review_required" then "Review required"
    end
  end

  def github_pr_checks_label(pull_request)
    case pull_request.check_status
    when "passing" then "Checks passing"
    when "pending" then "Checks pending"
    when "failing" then "Checks failing"
    end
  end
end
