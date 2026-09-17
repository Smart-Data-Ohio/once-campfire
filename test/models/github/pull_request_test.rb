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

  test "repository names are stored downcased so links in any case share one row" do
    first = Github::PullRequest.for_reference(owner: "Smart-Data-Ohio", repo: "Once-Campfire", number: 5)
    assert_equal "smart-data-ohio", first.owner
    assert_equal "once-campfire", first.repo

    message = @room.messages.create!(
      creator: @creator,
      markdown_source: "see https://github.com/smart-data-ohio/once-campfire/pull/5",
      client_message_id: "pr-case-reuse"
    )

    assert_equal [ first ], message.github_pull_requests
    assert_equal 1, Github::PullRequest.where(number: 5).count
  end

  test "display_full_name keeps the fetched repository name case" do
    pull_request = Github::PullRequest.for_reference(owner: "Smart-Data-Ohio", repo: "Once-Campfire", number: 5)
    assert_equal "smart-data-ohio/once-campfire", pull_request.display_full_name

    pull_request.update!(html_url: "https://github.com/Smart-Data-Ohio/Once-Campfire/pull/5")
    assert_equal "Smart-Data-Ohio/Once-Campfire", pull_request.display_full_name

    pull_request.update!(payload: { "base" => { "repo" => { "full_name" => "Smart-Data-Ohio/Once-Campfire" } } })
    assert_equal "Smart-Data-Ohio/Once-Campfire", pull_request.display_full_name
  end

  test "display_full_name falls back to the stored names" do
    pull_request = Github::PullRequest.for_reference(owner: "smart-data-ohio", repo: "once-campfire", number: 5)
    pull_request.update!(payload: { "base" => { "repo" => { "full_name" => "not a name" } } }, html_url: nil)

    assert_equal "smart-data-ohio/once-campfire", pull_request.display_full_name
  end

  test "collapse_case_duplicates! merges case variants onto the lowest id and repoints links and threads" do
    winner = Github::PullRequest.for_reference(owner: "rails", repo: "rails", number: 12)
    solo = Github::PullRequest.for_reference(owner: "rails", repo: "rails", number: 13)
    loser = Github::PullRequest.for_reference(owner: "rails", repo: "rails", number: 14)
    loser.update_columns(owner: "Rails", repo: "Rails", number: 12)
    solo.update_columns(owner: "Rails", repo: "Rails", number: 13)

    watercooler = rooms(:watercooler)

    linked = @room.messages.create!(
      creator: @creator, markdown_source: "no links here", client_message_id: "collapse-linked"
    )
    Github::PullRequestReference.create!(message: linked, pull_request: loser)
    double_linked = @room.messages.create!(
      creator: @creator, markdown_source: "no links here either", client_message_id: "collapse-double"
    )
    Github::PullRequestReference.create!(message: double_linked, pull_request: winner)
    Github::PullRequestReference.create!(message: double_linked, pull_request: loser)

    repoint_parent = watercooler.messages.create!(
      creator: @creator, markdown_source: "watercooler link", client_message_id: "collapse-repoint"
    )
    repoint_thread = ChannelThread.create!(room: watercooler, creator: @creator, name: "WC chat", parent_message: repoint_parent)
    repoint_mapping = Github::PullRequestThread.create!(pull_request: loser, room: watercooler, channel_thread: repoint_thread)

    clash_parent = @room.messages.create!(
      creator: @creator, markdown_source: "clash link", client_message_id: "collapse-clash"
    )
    clash_thread = ChannelThread.create!(room: @room, creator: @creator, name: "Clash chat", parent_message: clash_parent)
    clash_mapping = Github::PullRequestThread.create!(pull_request: loser, room: @room, channel_thread: clash_thread)
    kept_parent = @room.messages.create!(
      creator: @creator, markdown_source: "kept link", client_message_id: "collapse-kept"
    )
    kept_thread = ChannelThread.create!(room: @room, creator: @creator, name: "Kept chat", parent_message: kept_parent)
    kept_mapping = Github::PullRequestThread.create!(pull_request: winner, room: @room, channel_thread: kept_thread)

    Github::PullRequest.collapse_case_duplicates!

    assert_equal [ winner.id, solo.id ].sort, Github::PullRequest.ids.sort
    assert_equal "rails", solo.reload.owner
    assert_equal [ winner ], linked.reload.github_pull_requests
    assert_equal [ winner ], double_linked.reload.github_pull_requests
    assert_equal winner.id, repoint_mapping.reload.github_pull_request_id
    assert_equal winner.id, kept_mapping.reload.github_pull_request_id
    assert_not Github::PullRequestThread.exists?(clash_mapping.id)
    assert ChannelThread.exists?(clash_thread.id)
  end

  test "stale? is true until fetched and after ten minutes" do
    pull_request = Github::PullRequest.for_reference(owner: "rails", repo: "rails", number: 1)
    assert pull_request.stale?

    pull_request.update!(fetched_at: 11.minutes.ago)
    assert pull_request.stale?

    pull_request.update!(fetched_at: 9.minutes.ago)
    assert_not pull_request.stale?
  end

  test "claim_fetch_request! grants one fetch per PR per ten minutes" do
    pull_request = Github::PullRequest.for_reference(owner: "rails", repo: "rails", number: 50)

    assert pull_request.claim_fetch_request!
    assert pull_request.fetch_requested_recently?
    assert_not pull_request.claim_fetch_request!

    pull_request.update_column(:fetch_requested_at, 11.minutes.ago)
    assert_not pull_request.reload.fetch_requested_recently?
    assert pull_request.claim_fetch_request!
  end

  test "claiming a fetch request does not broadcast a card update" do
    message = @room.messages.create!(
      creator: @creator, markdown_source: "see https://github.com/rails/rails/pull/52",
      client_message_id: "pr-claim-quiet"
    )
    pull_request = message.github_pull_requests.first
    pull_request.update_column(:fetch_requested_at, nil) # creating the message claimed once already

    assert_broadcasts room_messages_stream_name(@room), 0 do
      assert pull_request.claim_fetch_request!
    end
  end

  test "with_rendering_details preloads referenced PRs" do
    message = @room.messages.create!(
      creator: @creator, markdown_source: "see https://github.com/rails/rails/pull/51",
      client_message_id: "pr-preload-1"
    )

    loaded = Message.with_rendering_details.find(message.id)

    assert_predicate loaded.association(:github_pull_requests), :loaded?
    assert_equal [ 51 ], loaded.github_pull_requests.map(&:number)
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

  test "card broadcasts carry the title for a public pull request and only a frame for a private one" do
    message = @room.messages.create!(
      creator: @creator, markdown_source: "https://github.com/rails/rails/pull/10",
      client_message_id: "pr-ref-private-broadcast"
    )
    pull_request = message.github_pull_requests.first
    stream = room_messages_stream_name(@room)

    pull_request.update!(private: false)
    broadcasts = capture_broadcasts(stream) { pull_request.update!(title: "Public title") }
    assert_equal 1, broadcasts.size
    assert_includes broadcasts.first.to_s, "Public title"

    pull_request.update!(private: true)
    broadcasts = capture_broadcasts(stream) { pull_request.update!(title: "Secret title") }
    assert_equal 1, broadcasts.size
    assert_no_match "Secret title", broadcasts.first.to_s
    assert_includes broadcasts.first.to_s, "turbo-frame"
  end

  private
    def room_messages_stream_name(room)
      signed = Turbo::StreamsChannel.signed_stream_name([ room, :messages ])
      Turbo::StreamsChannel.verified_stream_name(signed)
    end
end
