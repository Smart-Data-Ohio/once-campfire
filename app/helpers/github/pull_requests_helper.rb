module Github::PullRequestsHelper
  # PRs referenced by a message, sorted by repository and number. Rendering
  # a stale card re-enqueues a fetch so rarely viewed cards converge without
  # a webhook; the fetch updates fetched_at, so this cannot loop.
  def github_pr_cards_for(message)
    # Sorting in Ruby rather than with an `order` scope, because applying a
    # scope to an association builds a fresh relation and so ignores the rows
    # `with_rendering_details` already preloaded — one extra query per message
    # rendered. (Same reason `ordered_boosts` exists.)
    pull_requests = message.github_pull_requests.sort_by { |pr| [ pr.owner, pr.repo, pr.number ] }

    pull_requests.each do |pull_request|
      request_pr_refresh(pull_request)
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
    else "No checks"
    end
  end

  private
    # Enqueue a refresh for a stale card, bounded two ways: once per PR per
    # render (this helper instance lives for one request, so the set needs no
    # clearing), and at most one enqueue per PR per staleness window across
    # renders via the record's fetch-request claim.
    def request_pr_refresh(pull_request)
      return unless pull_request.stale?
      return unless (@github_pr_fetches ||= Set.new).add?(pull_request.id)

      Github::FetchPullRequestJob.perform_later(pull_request) if pull_request.claim_fetch_request!
    end
end
