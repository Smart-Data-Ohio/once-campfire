require "test_helper"

class Github::PullRequestTest < ActiveSupport::TestCase
  include ActionCable::TestHelper

  setup do
    @room = rooms(:designers)
    @creator = users(:david)
  end

  test "for_reference upserts by owner, repo, and number" do
    first = Github::PullRequest.for_reference(owner: "rails", repo: "rails", number: 1)
    second = Github::PullRequest.for_reference(owner: "rails", repo: "rails", number: 1)

    assert_equal first, second
    assert_equal 1, Github::PullRequest.where(owner: "rails", repo: "rails", number: 1).count
  end

  test "stale? is true until fetched and after ten minutes" do
    pull_request = Github::PullRequest.for_reference(owner: "rails", repo: "rails", number: 1)
    assert pull_request.stale?

    pull_request.update!(fetched_at: 11.minutes.ago)
    assert pull_request.stale?

    pull_request.update!(fetched_at: 9.minutes.ago)
    assert_not pull_request.stale?
  end

  test "creating a message with a PR URL references the PR and enqueues a fetch" do
    assert_enqueued_with(job: Github::FetchPullRequestJob) do
      @message = @room.messages.create!(
        creator: @creator, markdown_source: "review https://github.com/rails/rails/pull/123",
        client_message_id: "pr-ref-1"
      )
    end

    pull_request = Github::PullRequest.find_by(owner: "rails", repo: "rails", number: 123)
    assert pull_request
    assert_equal [ pull_request ], @message.github_pull_requests
    # The stored body is untouched: references live in the join table.
    assert_not_includes @message.reload.markdown_source, "github-pr-card"
  end

  test "duplicate URLs in one message create a single reference" do
    message = @room.messages.create!(
      creator: @creator,
      markdown_source: "https://github.com/rails/rails/pull/1 and again https://github.com/rails/rails/pull/1",
      client_message_id: "pr-ref-dup"
    )

    assert_equal 1, message.github_pull_request_references.count
  end

  test "a message without a PR URL references nothing and enqueues nothing" do
    assert_no_enqueued_jobs only: Github::FetchPullRequestJob do
      message = @room.messages.create!(
        creator: @creator, markdown_source: "just chatting", client_message_id: "pr-ref-none"
      )
      assert_empty message.github_pull_requests
    end
  end

  test "editing a message to add a PR URL adds the reference" do
    message = @room.messages.create!(
      creator: @creator, markdown_source: "just chatting", client_message_id: "pr-ref-edit"
    )
    assert_empty message.github_pull_requests

    assert_enqueued_with(job: Github::FetchPullRequestJob) do
      message.update!(markdown_source: "now with https://github.com/rails/rails/pull/7")
    end

    assert_equal [ 7 ], message.reload.github_pull_requests.map(&:number)
  end

  test "editing a message to remove a PR URL drops the reference" do
    message = @room.messages.create!(
      creator: @creator, markdown_source: "see https://github.com/rails/rails/pull/8",
      client_message_id: "pr-ref-remove"
    )
    assert_equal 1, message.github_pull_request_references.count

    message.update!(markdown_source: "never mind")
    assert_empty message.reload.github_pull_requests
  end

  test "updating a record broadcasts a card replace to each referencing room once" do
    other_room = rooms(:watercooler)
    message = @room.messages.create!(
      creator: @creator, markdown_source: "https://github.com/rails/rails/pull/9",
      client_message_id: "pr-ref-broadcast"
    )
    pull_request = message.github_pull_requests.first

    stream = room_messages_stream_name(@room)
    other_stream = room_messages_stream_name(other_room)

    assert_broadcasts stream, 1 do
      assert_broadcasts other_stream, 0 do
        pull_request.update!(title: "A new title")
      end
    end
  end

  private
    def room_messages_stream_name(room)
      signed = Turbo::StreamsChannel.signed_stream_name([ room, :messages ])
      Turbo::StreamsChannel.verified_stream_name(signed)
    end
end
