module Github
  # Reconciles a message's PR references with the URLs its content currently
  # contains, and enqueues a fetch for every newly referenced or stale PR.
  # Idempotent: re-running with unchanged content enqueues nothing new.
  module PullRequestReferenceSync
    class << self
      def call(message)
        triples = PullRequestUrl.extract(reference_text(message))

        pull_requests = triples.map do |ref|
          PullRequest.for_reference(owner: ref.owner, repo: ref.repo, number: ref.number)
        end

        message.github_pull_request_references
          .where.not(github_pull_request_id: pull_requests.map(&:id))
          .delete_all

        pull_requests.each do |pull_request|
          reference = message.github_pull_request_references.find_or_create_by!(pull_request: pull_request)
          Github::FetchPullRequestJob.perform_later(pull_request) if reference.previously_new_record? || pull_request.stale?
        end
      rescue ActiveRecord::RecordNotUnique
        retry
      end

      private
        def reference_text(message)
          [ message.markdown_source, message.plain_text_body ].compact_blank.join("\n")
        end
    end
  end
end
