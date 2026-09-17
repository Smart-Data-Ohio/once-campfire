require "test_helper"

class Github::PullRequestThreadTest < ActiveSupport::TestCase
  setup do
    @room = rooms(:designers)
    @pull_request = Github::PullRequest.for_reference(owner: "rails", repo: "rails", number: 12)
    @parent = @room.messages.create!(
      creator: users(:david),
      markdown_source: "review https://github.com/rails/rails/pull/12",
      client_message_id: "pr-thread-model-#{@pull_request.id}"
    )
  end

  test "one thread per PR per room, and a thread discusses at most one PR" do
    thread = ChannelThread.create!(room: @room, creator: users(:david), name: "PR chat", parent_message: @parent)
    Github::PullRequestThread.create!(pull_request: @pull_request, room: @room, channel_thread: thread)

    other_parent = @room.messages.create!(
      creator: users(:david), markdown_source: "another link https://github.com/rails/rails/pull/12",
      client_message_id: "pr-thread-model-other"
    )
    other_thread = ChannelThread.create!(room: @room, creator: users(:david), name: "Other chat", parent_message: other_parent)

    duplicate = Github::PullRequestThread.new(pull_request: @pull_request, room: @room, channel_thread: other_thread)
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:github_pull_request_id], "has already been taken"

    other_pr = Github::PullRequest.for_reference(owner: "rails", repo: "rails", number: 13)
    reshared = Github::PullRequestThread.new(pull_request: other_pr, room: @room, channel_thread: thread)
    assert_not reshared.valid?
    assert_includes reshared.errors[:channel_thread_id], "has already been taken"
  end

  test "the same PR can be discussed in different rooms" do
    thread = ChannelThread.create!(room: @room, creator: users(:david), name: "PR chat", parent_message: @parent)
    Github::PullRequestThread.create!(pull_request: @pull_request, room: @room, channel_thread: thread)

    other_room = rooms(:watercooler)
    other_parent = other_room.messages.create!(
      creator: users(:david), markdown_source: "https://github.com/rails/rails/pull/12",
      client_message_id: "pr-thread-model-cross-room"
    )
    other_thread = ChannelThread.create!(room: other_room, creator: users(:david), name: "PR chat", parent_message: other_parent)

    mapping = Github::PullRequestThread.create!(pull_request: @pull_request, room: other_room, channel_thread: other_thread)
    assert mapping.persisted?
  end

  test "create_or_reuse! creates the mapping once" do
    thread = ChannelThread.create!(room: @room, creator: users(:david), name: "PR chat", parent_message: @parent)

    assert_difference -> { Github::PullRequestThread.count }, 1 do
      mapping = Github::PullRequestThread.create_or_reuse!(pull_request: @pull_request, room: @room, channel_thread: thread)
      assert_equal thread, mapping.channel_thread
    end
  end

  test "create_or_reuse! reuses the winner when a concurrent insert loses" do
    thread = ChannelThread.create!(room: @room, creator: users(:david), name: "PR chat", parent_message: @parent)
    winner = Github::PullRequestThread.create!(pull_request: @pull_request, room: @room, channel_thread: thread)

    other_parent = @room.messages.create!(
      creator: users(:david), markdown_source: "https://github.com/rails/rails/pull/12 again",
      client_message_id: "pr-thread-model-race"
    )
    loser_thread = ChannelThread.create!(room: @room, creator: users(:david), name: "Racy chat", parent_message: other_parent)

    # The loser's validations passed before the winner committed, so its
    # insert fails at the unique index: simulate that losing insert.
    Github::PullRequestThread.stubs(:create!).raises(ActiveRecord::RecordNotUnique.new("index_github_pr_threads_on_pr_and_room"))

    assert_no_difference -> { Github::PullRequestThread.count } do
      mapping = Github::PullRequestThread.create_or_reuse!(pull_request: @pull_request, room: @room, channel_thread: loser_thread)
      assert_equal winner, mapping
    end
  end

  test "the unique index rejects a duplicate mapping without validations" do
    thread = ChannelThread.create!(room: @room, creator: users(:david), name: "PR chat", parent_message: @parent)
    Github::PullRequestThread.create!(pull_request: @pull_request, room: @room, channel_thread: thread)

    other_parent = @room.messages.create!(
      creator: users(:david), markdown_source: "https://github.com/rails/rails/pull/12 indexed",
      client_message_id: "pr-thread-model-index"
    )
    other_thread = ChannelThread.create!(room: @room, creator: users(:david), name: "Indexed chat", parent_message: other_parent)

    duplicate = Github::PullRequestThread.new(pull_request: @pull_request, room: @room, channel_thread: other_thread)
    assert_raises(ActiveRecord::RecordNotUnique) { duplicate.save!(validate: false) }
  end

  test "destroying the thread destroys the mapping" do
    thread = ChannelThread.create!(room: @room, creator: users(:david), name: "PR chat", parent_message: @parent)
    Github::PullRequestThread.create!(pull_request: @pull_request, room: @room, channel_thread: thread)

    assert_difference -> { Github::PullRequestThread.count }, -1 do
      thread.destroy!
    end
  end

  test "payload_for_message carries the PR object in a PR thread" do
    @pull_request.update!(
      title: "Fix login", state: "open", base_branch: "main", head_branch: "shiny",
      review_decision: "approved", check_status: "passing",
      html_url: "https://github.com/rails/rails/pull/12"
    )
    thread = ChannelThread.create!(room: @room, creator: users(:david), name: "PR chat", parent_message: @parent)
    Github::PullRequestThread.create!(pull_request: @pull_request, room: @room, channel_thread: thread)
    message = thread.post_message!(creator: users(:david), attributes: { markdown_source: "looks good" })

    assert_equal(
      {
        url: "https://github.com/rails/rails/pull/12",
        owner: "rails",
        repo: "rails",
        number: 12,
        title: "Fix login",
        state: "open",
        head_branch: "shiny",
        base_branch: "main",
        review_decision: "approved",
        checks_state: "passing"
      },
      Github::PullRequestThread.payload_for_message(message)
    )
  end

  test "payload_for_message is null in other threads and room messages" do
    thread = ChannelThread.create!(room: @room, creator: users(:david), name: "Ordinary chat", parent_message: @parent)
    reply = thread.post_message!(creator: users(:david), attributes: { markdown_source: "hello" })

    assert_nil Github::PullRequestThread.payload_for_message(reply)
    assert_nil Github::PullRequestThread.payload_for_message(@parent)
  end
end
