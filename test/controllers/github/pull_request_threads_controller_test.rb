require "test_helper"

class Github::PullRequestThreadsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in :david
    @room = rooms(:designers)
    @message = @room.messages.create!(
      creator: users(:david),
      markdown_source: "review https://github.com/rails/rails/pull/12",
      client_message_id: "discuss-card-1"
    )
    @pull_request = @message.github_pull_requests.first
  end

  test "discuss creates a thread with the card message as parent and records the mapping" do
    assert_difference -> { @room.channel_threads.count }, 1 do
      assert_difference -> { Github::PullRequestThread.count }, 1 do
        assert_enqueued_with(job: Github::FetchPullRequestJob) do
          post room_github_pull_request_threads_url(@room),
            params: { pull_request_id: @pull_request.id, message_id: @message.id }
        end
      end
    end

    thread = @room.channel_threads.order(:created_at).last
    assert_redirected_to room_thread_path(@room, thread)
    assert_equal @message, thread.parent_message
    assert_equal users(:david), thread.creator
    assert thread.membership_for(users(:david)).present?

    mapping = Github::PullRequestThread.find_by!(pull_request: @pull_request, room: @room)
    assert_equal thread, mapping.channel_thread
  end

  test "discuss reuses the room's existing thread for the PR" do
    post room_github_pull_request_threads_url(@room),
      params: { pull_request_id: @pull_request.id, message_id: @message.id }
    thread = @room.channel_threads.order(:created_at).last

    other_message = @room.messages.create!(
      creator: users(:jz),
      markdown_source: "also https://github.com/rails/rails/pull/12",
      client_message_id: "discuss-card-2"
    )

    assert_no_difference [ -> { ChannelThread.count }, -> { Github::PullRequestThread.count } ] do
      post room_github_pull_request_threads_url(@room),
        params: { pull_request_id: @pull_request.id, message_id: other_message.id }
    end

    assert_redirected_to room_thread_path(@room, thread)
  end

  test "discuss reuses one row when a concurrent creation wins the race" do
    existing_thread = ChannelThread.create!(room: @room, creator: users(:jz), name: "PR chat", parent_message: @message)
    ThreadMembership.join!(existing_thread, users(:jz))
    winner = Github::PullRequestThread.create!(pull_request: @pull_request, room: @room, channel_thread: existing_thread)

    Github::PullRequestThread.stubs(:create_or_reuse!).returns(winner)

    assert_no_difference [ -> { ChannelThread.count }, -> { Github::PullRequestThread.count } ] do
      post room_github_pull_request_threads_url(@room),
        params: { pull_request_id: @pull_request.id, message_id: @message.id }
    end

    assert_redirected_to room_thread_path(@room, existing_thread)
  end

  test "non-members get not found" do
    sign_in :kevin # not a member of the watercooler
    room = rooms(:watercooler)
    message = room.messages.create!(
      creator: users(:david),
      markdown_source: "https://github.com/rails/rails/pull/12",
      client_message_id: "discuss-card-private"
    )

    # RoomScoped raises RecordNotFound, which renders 404 outside tests.
    assert_raises(ActiveRecord::RecordNotFound) do
      post room_github_pull_request_threads_url(room),
        params: { pull_request_id: message.github_pull_requests.first.id, message_id: message.id }
    end
  end

  test "a message that does not reference the PR gets not found" do
    other_pr = Github::PullRequest.for_reference(owner: "rails", repo: "rails", number: 13)

    assert_raises(ActiveRecord::RecordNotFound) do
      post room_github_pull_request_threads_url(@room),
        params: { pull_request_id: other_pr.id, message_id: @message.id }
    end

    assert_empty Github::PullRequestThread.all
  end

  test "a thread reply cannot parent a discussion" do
    thread = ChannelThread.create!(room: @room, creator: users(:david), name: "Ordinary chat", parent_message: @message)
    reply = thread.post_message!(
      creator: users(:david), attributes: { markdown_source: "https://github.com/rails/rails/pull/12 in a thread" }
    )

    assert_raises(ActiveRecord::RecordNotFound) do
      post room_github_pull_request_threads_url(@room),
        params: { pull_request_id: @pull_request.id, message_id: reply.id }
    end

    assert_empty Github::PullRequestThread.all
  end
end
