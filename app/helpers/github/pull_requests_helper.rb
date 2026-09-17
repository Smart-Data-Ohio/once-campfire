module Github::PullRequestsHelper
  # Cache key for a message rendered with its PR and event cards. Neither
  # update ever touches the message, so the key folds in the newest card row
  # of either kind; otherwise a collection cache would keep serving "Loading
  # pull request" (or a stale event card) indefinitely. Cards with a PR link
  # also fold in the room's discussion-thread stamp, so a cached Discuss
  # control flips to its thread link once one is created.
  def message_with_pr_cards_cache_key(message)
    newest_card = (message.github_pull_requests.map(&:updated_at) + message.events.map(&:updated_at)).compact.max
    key = [ message, newest_card ]
    key << github_pr_threads_stamp(message.room_id) if message.github_pull_requests.any?
    key
  end

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

  # The room's discussion-thread mapping for a PR card's Discuss control,
  # if one exists. Mappings preload once per room per render, so any number
  # of cards costs one query.
  def github_pr_thread_mapping_for(room_id, pull_request)
    github_pr_threads_for_room(room_id)[pull_request.id]
  end

  # The PR a thread discusses, if any. Like message cards, the thread
  # header refreshes a stale card so rarely viewed threads converge.
  def github_pr_thread_pull_request(thread)
    pull_request = thread.pull_request_thread&.pull_request
    request_pr_refresh(pull_request) if pull_request
    pull_request
  end

  # True only when the repository is known public. nil means unknown and is
  # treated as private everywhere: the safe default until a fetch records
  # the repository's privacy.
  def github_pr_public?(pull_request)
    pull_request.private == false
  end

  # Frame ids for the per-viewer card frames. The cards container and the
  # thread header render the empty frame with these ids; the card endpoint
  # recomputes the same id from its message/thread param so the loaded
  # frame replaces the placeholder.
  def github_pr_card_frame_id(pull_request, message_id: nil, thread_id: nil)
    if message_id
      dom_id(pull_request, "card_for_message_#{message_id}")
    else
      dom_id(pull_request, "card_for_thread_#{thread_id}")
    end
  end

  # Whether the viewer may see the PR's card content. Public repositories
  # are visible to every room member; private (or still unknown) ones only
  # to members whose own linked GitHub account can read the repository,
  # checked with their token against GET /repos/{owner}/{repo}.
  #
  # The decision is cached per viewer and repository for 10 minutes, both
  # grants and denials, so a page of cards from one repository costs at
  # most one GitHub request per viewer per window. The key carries the
  # linked account's updated_at, so linking, relinking, or repairing the
  # account invalidates that member's cached decisions without enumerating
  # repositories. Members without a usable linked account are denied with
  # no request, and a transport failure denies without caching so the next
  # load retries.
  def github_pr_visible_to?(pull_request, user)
    return true if github_pr_public?(pull_request)

    account = user&.github_connected_account
    return false unless account&.usable?

    Rails.cache.fetch([ "github_repo_access", user.id, account.updated_at, pull_request.owner, pull_request.repo ], expires_in: 10.minutes) do
      Github::WriteClient.new(token: account.access_token)
        .repository_readable?(pull_request.owner, pull_request.repo)
    rescue Github::WriteClient::Unauthorized
      account.mark_disconnected!("GitHub rejected the linked token (401)")
      false
    end
  rescue ActiveRecord::Encryption::Errors::Decryption
    account.mark_disconnected!(GithubConnectedAccount::UNREADABLE_TOKEN_REASON)
    false
  rescue Github::WriteClient::Error
    false
  end

  private
    def github_pr_threads_for_room(room_id)
      id = room_id.is_a?(Room) ? room_id.id : room_id.to_i
      (@github_pr_threads_by_room ||= {})[id] ||=
        Github::PullRequestThread.where(room_id: id).index_by(&:github_pull_request_id)
    end

    def github_pr_threads_stamp(room_id)
      github_pr_threads_for_room(room_id).values.map(&:updated_at).max
    end

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
