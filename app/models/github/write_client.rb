require "net/http"

module Github
  # Authenticated GitHub REST API client backing PR write actions. Posts
  # issue comments, pull-request reviews, and review requests as the linked
  # user's own GitHub identity, using their personal access token — never
  # the workspace token.
  #
  # Never raises for transport problems without mapping them: callers rescue
  # WriteClient::Error. Never logs tokens, headers, or bodies.
  class WriteClient
    API_HOST = "api.github.com"
    API_VERSION = "2022-11-28"
    TIMEOUT = 10

    class Error < StandardError; end
    class Unauthorized < Error; end
    class Refused < Error; end

    # The login the token belongs to, or raises Unauthorized when GitHub
    # rejects it. Used to validate a pasted token at link time.
    def self.authenticated_login(token)
      new(token: token).get_user.fetch("login").to_s.then do |login|
        raise Error, "GitHub did not return a login" if login.blank?
        login
      end
    end

    def initialize(token:)
      @token = token
    end

    # POST /repos/{owner}/{repo}/issues/{number}/comments
    def create_issue_comment(pull_request, body:)
      post(pull_request, "issues/#{pull_request.number}/comments", { body: body })
    end

    # POST /repos/{owner}/{repo}/pulls/{number}/reviews
    def create_review(pull_request, event:, body: nil)
      payload = { event: event }
      payload[:body] = body if body.present?
      post(pull_request, "pulls/#{pull_request.number}/reviews", payload)
    end

    # POST /repos/{owner}/{repo}/pulls/{number}/requested_reviewers
    def request_reviewers(pull_request, logins:)
      post(pull_request, "pulls/#{pull_request.number}/requested_reviewers", { reviewers: logins })
    end

    def get_user
      uri = URI::HTTPS.build(host: API_HOST, path: "/user")
      request(uri) { |http| http.get(uri.request_uri, headers) }
    end

    # GET /repos/{owner}/{repo}: true when the token's user can read the
    # repository, backing the per-viewer gate for private-repo cards. 403
    # and 404 both mean no access (GitHub answers 404 for repositories the
    # token cannot see). 401 raises Unauthorized like the write calls, so
    # callers mark the account disconnected the same way.
    def repository_readable?(owner, repo)
      uri = URI::HTTPS.build(host: API_HOST, path: "/repos/#{owner}/#{repo}")
      request(uri) { |http| http.get(uri.request_uri, headers) }
      true
    rescue Refused
      false
    end

    private
      def post(pull_request, relative_path, payload)
        uri = URI::HTTPS.build(host: API_HOST,
          path: "/repos/#{pull_request.owner}/#{pull_request.repo}/#{relative_path}")
        request(uri) { |http| http.post(uri.request_uri, payload.to_json, headers) }
      end

      def request(uri)
        response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: TIMEOUT, read_timeout: TIMEOUT) do |http|
          yield http
        end

        case response
        when Net::HTTPSuccess, Net::HTTPCreated
          parse_body(response)
        when Net::HTTPUnauthorized
          raise Unauthorized, "GitHub rejected the linked token"
        when Net::HTTPForbidden, Net::HTTPNotFound
          raise Refused, "GitHub refused: #{github_message(response)}"
        when Net::HTTPUnprocessableEntity
          raise Refused, "GitHub refused: #{github_message(response)}"
        else
          raise Error, "GitHub returned #{response.code}"
        end
      rescue Unauthorized, Refused
        raise
      rescue Error
        raise
      rescue StandardError => error
        Rails.logger.warn "Github::WriteClient request failed: #{error.class}"
        raise Error, "Could not reach GitHub (#{error.class.name.demodulize.titleize})"
      end

      def parse_body(response)
        JSON.parse(response.body.presence || "{}")
      rescue JSON::ParserError
        {}
      end

      # GitHub's own error message, kept inline. A zero-width space splits
      # "@[" so a hostile message can never become a mention token.
      def github_message(response)
        message = parse_body(response)["message"].to_s.gsub("@[", "@\u200B[").gsub(/[\r\n]+/, " ").strip
        message.presence || "request was not allowed"
      end

      def headers
        {
          "Accept" => "application/vnd.github+json",
          "X-GitHub-Api-Version" => API_VERSION,
          "User-Agent" => "Smartfire-GitHub-Writes",
          "Content-Type" => "application/json",
          "Authorization" => "Bearer #{@token}"
        }
      end
  end
end
