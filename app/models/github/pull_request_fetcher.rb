require "net/http"

module Github
  # Read-only GitHub REST API client backing PR cards. Fetches a pull
  # request, its head commit's check runs and combined status, and its
  # reviews, then persists the card fields on the record.
  #
  # Never raises for expected failures (HTTP errors, rate limits, network
  # problems): those are recorded as fetch_error so the card can say the
  # PR could not be loaded. Never logs the workspace token.
  class PullRequestFetcher
    API_HOST = "api.github.com"
    API_VERSION = "2022-11-28"
    TIMEOUT = 10

    class FetchError < StandardError; end

    def initialize(pull_request, token: ENV["GITHUB_TOKEN"].presence)
      @pull_request = pull_request
      @token = token
    end

    def fetch
      data = fetch_pull_request
      sha = data["head"]["sha"]

      attributes = card_attributes(data).merge(
        review_decision: review_decision,
        check_status: check_status(sha),
        payload: data,
        fetched_at: Time.current,
        fetch_error: nil
      )

      merge_changed_files!(attributes, total_count: data["changed_files"])

      @pull_request.update!(attributes)
    rescue FetchError => error
      @pull_request.update!(fetched_at: Time.current, fetch_error: error.message)
    rescue StandardError => error
      Rails.logger.warn "Github::PullRequestFetcher failed for #{@pull_request.full_name}##{@pull_request.number}: #{error.class}"
      @pull_request.update!(fetched_at: Time.current, fetch_error: "Could not reach GitHub (#{error.class.name.demodulize.titleize})")
    end

    private
      def card_attributes(data)
        {
          private: data.dig("base", "repo", "private"),
          title: data["title"],
          author_login: data.dig("user", "login"),
          author_avatar_url: data.dig("user", "avatar_url"),
          state: card_state(data),
          base_branch: data.dig("base", "ref"),
          head_branch: data.dig("head", "ref"),
          head_sha: data.dig("head", "sha"),
          html_url: data["html_url"],
          github_updated_at: data["updated_at"]
        }
      end

      def card_state(data)
        if data["merged_at"].present?
          "merged"
        elsif data["state"] == "closed"
          "closed"
        elsif data["draft"]
          "draft"
        else
          "open"
        end
      end

      def review_decision
        decisions = fetch_reviews_latest_decisions
        if decisions.include?("CHANGES_REQUESTED")
          "changes_requested"
        elsif decisions.include?("APPROVED")
          "approved"
        else
          "review_required"
        end
      end

      # Latest submitted state per reviewer, ignoring comments.
      def fetch_reviews_latest_decisions
        reviews = get("pulls/#{@pull_request.number}/reviews?per_page=100")
        return [] unless reviews.is_a?(Array)

        reviews
          .select { |review| review["state"].in?(%w[ APPROVED CHANGES_REQUESTED ]) }
          .group_by { |review| review.dig("user", "id") || review.dig("user", "login") }
          .filter_map { |_, rs| rs.max_by { |r| r["submitted_at"].to_s }["state"] }
      rescue FetchError
        []
      end

      def check_status(sha)
        runs = get("commits/#{sha}/check-runs?per_page=100").fetch("check_runs", [])
        statuses = runs.filter_map { |run| run["status"] == "completed" ? run["conclusion"] : "pending" }

        combined = get("commits/#{sha}/status")
        combined_state = combined.fetch("state", nil)
        # The combined status reports "pending" when the commit has no
        # statuses at all: that means no CI ran, not that checks are running.
        has_statuses = combined.fetch("total_count", 0).to_i > 0
        if combined_state.present? && (combined_state != "pending" || (statuses.empty? && has_statuses))
          statuses << combined_state
        end

        if statuses.intersect?(%w[ failure error timed_out action_required ])
          "failing"
        elsif statuses.intersect?(%w[ pending in_progress queued requested waiting ])
          "pending"
        elsif statuses.intersect?(%w[ success neutral skipped ])
          "passing"
        end
      rescue FetchError
        nil
      end

      # Fetches the changed-files summary, but only for PRs with at least
      # one discussion thread: unmapped PRs never pay for the extra call.
      # Stores path, additions, deletions, and status per file, capped at
      # 100 — diff bodies are never stored. A failed files fetch keeps the
      # previous summary in place and records the existing fetch_error.
      def merge_changed_files!(attributes, total_count:)
        return unless @pull_request.pull_request_threads.exists?

        files = fetch_changed_files
        attributes.merge!(
          changed_files: {
            "files" => files,
            "total_count" => total_count.to_i.positive? ? total_count.to_i : files.size
          }.to_json,
          changed_files_fetched_at: Time.current
        )
      rescue FetchError => error
        attributes[:fetch_error] = error.message
      end

      def fetch_changed_files
        files = get("pulls/#{@pull_request.number}/files?per_page=100")
        return [] unless files.is_a?(Array)

        files.first(100).map do |file|
          {
            "filename" => file["filename"],
            "additions" => file["additions"].to_i,
            "deletions" => file["deletions"].to_i,
            "status" => file["status"]
          }
        end
      end

      def fetch_pull_request
        get("pulls/#{@pull_request.number}")
      end

      def get(path)
        relative_path, query = path.split("?", 2)
        uri = URI::HTTPS.build(host: API_HOST,
          path: "/repos/#{@pull_request.owner}/#{@pull_request.repo}/#{relative_path}", query: query)

        response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: TIMEOUT, read_timeout: TIMEOUT) do |http|
          http.get(uri.request_uri, headers)
        end

        case response
        when Net::HTTPSuccess
          JSON.parse(response.body)
        when Net::HTTPNotFound
          raise FetchError, "Pull request not found on GitHub"
        when Net::HTTPForbidden, Net::HTTPTooManyRequests
          raise FetchError, rate_limit_message(response)
        when Net::HTTPUnauthorized
          raise FetchError, "GitHub authentication failed"
        else
          raise FetchError, "GitHub returned #{response.code}"
        end
      end

      def headers
        {
          "Accept" => "application/vnd.github+json",
          "X-GitHub-Api-Version" => API_VERSION,
          "User-Agent" => "Smartfire-GitHub-Cards"
        }.tap do |h|
          h["Authorization"] = "Bearer #{@token}" if @token
        end
      end

      def rate_limit_message(response)
        if response["X-RateLimit-Remaining"] == "0"
          "GitHub rate limit exceeded#{rate_limit_reset_suffix(response)}"
        else
          "GitHub request forbidden"
        end
      end

      def rate_limit_reset_suffix(response)
        reset_at = Time.zone.at(response["X-RateLimit-Reset"].to_i).utc.to_fs(:short)
        ", resets #{reset_at}"
      rescue StandardError
        ""
      end
  end
end
