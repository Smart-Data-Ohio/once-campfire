module Github
  # One agent-requested pull-request write action: comment, approve,
  # request_changes, or request_review. Validates the agent's input with the
  # same rules as the human PR-thread endpoints, builds the approval's
  # action/summary/payload, and performs the GitHub call through the same
  # WriteClient methods the human controllers use. Never touches GitHub
  # until #perform, which only runs after a human approves.
  class AgentPullRequestAction
    include ActiveModel::Model

    KINDS = %w[ comment approve request_changes request_review ].freeze
    SUMMARY_EXCERPT_CHARS = 120

    # The approval payload column holds 4 KB, so bodies stay well under it;
    # the approval validation remains the backstop.
    MAX_BODY_CHARS = 3500

    attr_accessor :pull_request, :kind, :body, :reviewers

    validates :pull_request, presence: true
    validates :kind, inclusion: { in: KINDS, message: "must be one of: comment, approve, request_changes, request_review" }
    validate :body_requirements
    validate :body_length_within_payload
    validate :reviewers_requirements

    def self.from_payload(pull_request:, payload:)
      payload = payload.is_a?(Hash) ? payload : {}
      new(
        pull_request: pull_request,
        kind: payload["kind"],
        body: payload["body"],
        reviewers: payload["reviewers"]
      )
    end

    def normalized_body
      body.to_s.strip.presence
    end

    def normalized_reviewers
      ReviewLogins.normalize(reviewers)
    end

    def action_name
      "github.#{kind}"
    end

    def summary
      ref = "#{pull_request.full_name}##{pull_request.number}"
      case kind.to_s
      when "comment" then "Comment on #{ref}: #{normalized_body.to_s[0, SUMMARY_EXCERPT_CHARS]}"
      when "approve" then "Approve #{ref}"
      when "request_changes" then "Request changes on #{ref}"
      when "request_review" then "Request review on #{ref} from #{normalized_reviewers&.map { |login| "@#{login}" }&.join(", ")}".truncate(500)
      end
    end

    def payload_hash
      {
        "pull_request_id" => pull_request&.id,
        "kind" => kind.to_s,
        "body" => stored_body,
        "reviewers" => stored_reviewers
      }
    end

    def payload_json
      payload_hash.to_json
    end

    # Performs the GitHub call with the agent's own linked token. Returns
    # the parsed response; callers read html_url from it. Raises the same
    # WriteClient errors the human controllers rescue.
    def perform(write_client)
      case kind.to_s
      when "comment"
        write_client.create_issue_comment(pull_request, body: normalized_body)
      when "approve"
        write_client.create_review(pull_request, event: "APPROVE", body: normalized_body)
      when "request_changes"
        write_client.create_review(pull_request, event: "REQUEST_CHANGES", body: normalized_body)
      when "request_review"
        write_client.request_reviewers(pull_request, logins: normalized_reviewers)
      end
    end

    private
      def stored_body
        %w[ comment approve request_changes ].include?(kind.to_s) ? normalized_body : nil
      end

      def stored_reviewers
        kind.to_s == "request_review" ? normalized_reviewers.presence : nil
      end

      def body_requirements
        case kind.to_s
        when "comment"
          errors.add(:body, "is required for a comment") if normalized_body.blank?
        when "request_changes"
          errors.add(:body, "is required when requesting changes") if normalized_body.blank?
        end
      end

      def body_length_within_payload
        if normalized_body && normalized_body.length > MAX_BODY_CHARS
          errors.add(:body, "is too long (maximum is #{MAX_BODY_CHARS} characters)")
        end
      end

      def reviewers_requirements
        if kind.to_s == "request_review" && normalized_reviewers.blank?
          errors.add(:reviewers, ReviewLogins::INVALID_MESSAGE)
        end
      end
  end
end
