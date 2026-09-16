class Github::WebhooksController < ActionController::Base
  skip_forgery_protection

  HANDLED_EVENTS = %w[ pull_request pull_request_review check_suite check_run status ].freeze

  def create
    secret = ENV["GITHUB_WEBHOOK_SECRET"].presence
    return head(:service_unavailable) unless secret
    return head(:unauthorized) unless valid_signature?(secret)

    delivery_guid = request.headers["X-GitHub-Delivery"].to_s
    event = request.headers["X-GitHub-Event"].to_s
    return head(:unauthorized) if delivery_guid.blank?

    # Already processed (a GitHub redelivery): acknowledge without doing
    # anything so each update is received once.
    return head(:ok) unless Github::WebhookDelivery.claim!(delivery_guid, event: event)

    referenced_pull_requests(event, payload).each do |pull_request|
      Github::FetchPullRequestJob.perform_later(pull_request)
    end

    head :ok
  end

  private
    def payload
      @payload ||= JSON.parse(request.raw_post.presence || "{}")
    rescue JSON::ParserError
      {}
    end

    def valid_signature?(secret)
      signature = request.headers["X-Hub-Signature-256"].to_s
      expected = "sha256=#{OpenSSL::HMAC.hexdigest("SHA256", secret, request.raw_post)}"

      signature.start_with?("sha256=") && ActiveSupport::SecurityUtils.secure_compare(signature, expected)
    end

    # Stored PRs the workspace references that this event is about. Events
    # for anything else (unreferenced PRs, other event types) resolve to
    # nothing and are ignored.
    def referenced_pull_requests(event, payload)
      candidates =
        case event
        when "pull_request", "pull_request_review"
          pr_numbers_from_pull_request_payload(payload)
        when "check_suite"
          pr_numbers_from_check_payload(payload["check_suite"], payload)
        when "check_run"
          pr_numbers_from_check_payload(payload["check_run"], payload)
        when "status"
          pr_numbers_from_status_payload(payload)
        else
          []
        end

      candidates.filter_map do |owner, repo, number|
        Github::PullRequest.find_by(owner: owner, repo: repo, number: number)&.then do |pr|
          pr if pr.pull_request_references.exists?
        end
      end.uniq
    end

    def pr_numbers_from_pull_request_payload(payload)
      pr = payload["pull_request"]
      return [] unless pr

      full_name = pr.dig("base", "repo", "full_name") || payload.dig("repository", "full_name")
      number = pr["number"]
      return [] unless full_name && number

      [ full_name.split("/", 2) + [ number ] ]
    end

    def pr_numbers_from_check_payload(check, payload)
      full_name = payload.dig("repository", "full_name")
      pull_requests = check&.dig("pull_requests") || []
      return [] unless full_name

      owner, repo = full_name.split("/", 2)
      pull_requests.filter_map { |pr| [ owner, repo, pr["number"] ] if pr["number"] }
    end

    # Status events carry branches, not PR numbers, so match referenced
    # PRs in the repository whose head branch was pushed to.
    def pr_numbers_from_status_payload(payload)
      full_name = payload.dig("repository", "full_name")
      branches = (payload["branches"] || []).filter_map { |branch| branch["name"] }
      return [] unless full_name && branches.any?

      owner, repo = full_name.split("/", 2)
      Github::PullRequest.where(owner: owner, repo: repo, head_branch: branches).pluck(:owner, :repo, :number)
    end
end
