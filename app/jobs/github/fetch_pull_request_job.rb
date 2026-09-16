class Github::FetchPullRequestJob < ApplicationJob
  # The fetcher records every failure on the PR instead of raising, so a
  # missing record is the only thing left to discard: the PR was deleted
  # after the job was enqueued and there is nothing to update.
  discard_on ActiveJob::DeserializationError

  def perform(pull_request)
    Github::PullRequestFetcher.new(pull_request).fetch
  end
end
