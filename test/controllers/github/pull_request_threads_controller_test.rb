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

  test "discuss reuses the winner and drops the loser when the race is lost at the unique index" do
    simulate_mapping_race(ActiveRecord::RecordNotUnique.new("index_github_pr_threads_on_pr_and_room"))
    thread_ids_before = ChannelThread.ids

    assert_difference -> { Github::PullRequestThread.count }, 1 do
      post room_github_pull_request_threads_url(@room),
        params: { pull_request_id: @pull_request.id, message_id: @message.id }
    end

    assert_mapping_race_loser_cleaned_up(thread_ids_before)
  end

  test "discuss reuses the winner and drops the loser when the race is lost at the validation" do
    loser = Github::PullRequestThread.new(pull_request: @pull_request, room: @room, channel_thread: ChannelThread.new)
    loser.errors.add(:github_pull_request_id, :taken)
    simulate_mapping_race(ActiveRecord::RecordInvalid.new(loser))
    thread_ids_before = ChannelThread.ids

    assert_difference -> { Github::PullRequestThread.count }, 1 do
      post room_github_pull_request_threads_url(@room),
        params: { pull_request_id: @pull_request.id, message_id: @message.id }
    end

    assert_mapping_race_loser_cleaned_up(thread_ids_before)
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

  private
    # The race winner commits inside the loser's create path: the stubbed
    # create! first inserts the winner through the original method, then
    # raises the given uniqueness error for the loser's attempt. The winner
    # discusses from its own card message, since a message parents one thread.
    def simulate_mapping_race(error)
      real_create = Github::PullRequestThread.method(:create!)
      Github::PullRequestThread.stubs(:create!).with do |*args, **kwargs|
        winner_parent = @room.messages.create!(
          creator: users(:jz),
          markdown_source: "review https://github.com/rails/rails/pull/12",
          client_message_id: "race-winner-parent"
        )
        winner_thread = ChannelThread.create!(room: @room, creator: users(:jz), name: "Winning chat", parent_message: winner_parent)
        ThreadMembership.join!(winner_thread, users(:jz))
        attributes = args.first || kwargs
        real_create.call(attributes.merge(channel_thread: winner_thread))
        true
      end.raises(error)
    end

    def assert_mapping_race_loser_cleaned_up(thread_ids_before)
      assert_equal 1, Github::PullRequestThread.count
      mapping = Github::PullRequestThread.last
      assert_redirected_to room_thread_path(@room, mapping.channel_thread)
      assert_equal [ mapping.channel_thread_id ], ChannelThread.ids - thread_ids_before
    end
end
