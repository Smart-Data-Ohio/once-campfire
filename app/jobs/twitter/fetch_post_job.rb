class Twitter::FetchPostJob < ApplicationJob
  # The fetcher records every failure on the post instead of raising, so a
  # missing record is the only thing left to discard: the post was deleted
  # after the job was enqueued and there is nothing to update.
  discard_on ActiveJob::DeserializationError

  def perform(post)
    Twitter::PostFetcher.new(post).fetch
  end
end
