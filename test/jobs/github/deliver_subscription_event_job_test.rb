require "test_helper"

class Github::DeliverSubscriptionEventJobTest < ActiveJob::TestCase
  setup do
    @room = rooms(:designers)
    @subscription = Github::RepositorySubscription.create!(
      room: @room, owner: "rails", repo: "rails",
      events: %w[ opened merged closed review_requested review_submitted checks_failed ],
      created_by: users(:david))
  end

  test "opened posts one bot message with the pr url and reference" do
    assert_difference -> { @room.messages.count }, 1 do
      Github::DeliverSubscriptionEventJob.perform_now("pull_request", pull_request_payload(action: "opened"))
    end

    message = @room.messages.order(:created_at).last
    bot = User.active_bots.find_by!(name: "GitHub")
    assert_equal bot, message.creator
    assert_nil bot.agent
    assert_equal "**alice** opened pull request #12: Fix login\nhttps://github.com/rails/rails/pull/12", message.markdown_source
    assert_equal [ 12 ], message.github_pull_requests.map(&:number)
  end

  test "the posted url is built from the subscribed repository, not the payload" do
    payload = pull_request_payload(action: "opened")
    payload["pull_request"]["html_url"] = "https://github.com/evil/other/pull/99"

    Github::DeliverSubscriptionEventJob.perform_now("pull_request", payload)

    message = @room.messages.order(:created_at).last
    assert_includes message.markdown_source, "https://github.com/rails/rails/pull/12"
    assert_not_includes message.markdown_source, "evil/other"
  end

  test "webhook text cannot smuggle a mention token into the post" do
    payload = pull_request_payload(action: "opened")
    payload["pull_request"]["title"] = "Ping @[Everyone] please"

    Github::DeliverSubscriptionEventJob.perform_now("pull_request", payload)

    message = @room.messages.order(:created_at).last
    assert_no_match Message::Markdown::MENTION_TOKEN_PATTERN, message.markdown_source
    assert_includes message.markdown_source, "Everyone"
  end

  test "reopened, ready for review, and synchronize post nothing after opened" do
    Github::DeliverSubscriptionEventJob.perform_now("pull_request", pull_request_payload(action: "opened"))

    assert_no_difference -> { @room.messages.count } do
      Github::DeliverSubscriptionEventJob.perform_now("pull_request", pull_request_payload(action: "reopened"))
      Github::DeliverSubscriptionEventJob.perform_now("pull_request", pull_request_payload(action: "ready_for_review"))
      Github::DeliverSubscriptionEventJob.perform_now("pull_request", pull_request_payload(action: "synchronize"))
      Github::DeliverSubscriptionEventJob.perform_now("pull_request", pull_request_payload(action: "labeled"))
    end
  end

  test "reopened posts when the pr opened before the subscription" do
    Github::DeliverSubscriptionEventJob.perform_now("pull_request", pull_request_payload(action: "reopened"))

    message = @room.messages.order(:created_at).last
    assert_equal "**alice** reopened pull request #12: Fix login\nhttps://github.com/rails/rails/pull/12", message.markdown_source
  end

  test "closed with merged true posts merged, merged false posts closed" do
    Github::DeliverSubscriptionEventJob.perform_now("pull_request", pull_request_payload(action: "closed", merged: true))

    message = @room.messages.order(:created_at).last
    assert_equal "**alice** merged #12: Fix login\nhttps://github.com/rails/rails/pull/12", message.markdown_source

    Github::DeliverSubscriptionEventJob.perform_now("pull_request", pull_request_payload(action: "closed", merged: false, number: 13))

    message = @room.messages.order(:created_at).last
    assert_equal "**alice** closed #13: Fix login\nhttps://github.com/rails/rails/pull/13", message.markdown_source
  end

  test "review_requested posts and records an inbox item for the linked member" do
    users(:kevin).update!(github_login: "kevin-gh")

    assert_difference -> { ActivityItem.where(user: users(:kevin), event_type: "pr_review_request").count }, 1 do
      Github::DeliverSubscriptionEventJob.perform_now("pull_request", pull_request_payload(action: "review_requested", reviewer: "Kevin-GH"))
    end

    message = @room.messages.order(:created_at).last
    assert_equal "**bob** requested a review from **Kevin-GH** on #12: Fix login\nhttps://github.com/rails/rails/pull/12", message.markdown_source

    item = ActivityItem.find_by!(user: users(:kevin), event_type: "pr_review_request")
    assert_equal message, item.source
    assert_includes ActivityItem.accessible_to(users(:kevin)), item

    memberships(:kevin_designers).delete
    assert_not ActivityItem.accessible_to(users(:kevin)).exists?(item.id)
  end

  test "review_requested records nothing for non-members or unlinked logins" do
    users(:kevin).update!(github_login: "kevin-gh")

    assert_no_difference -> { ActivityItem.where(event_type: "pr_review_request").count } do
      Github::DeliverSubscriptionEventJob.perform_now("pull_request", pull_request_payload(action: "review_requested", reviewer: "stranger"))
    end

    memberships(:kevin_designers).delete
    assert_no_difference -> { ActivityItem.where(event_type: "pr_review_request").count } do
      Github::DeliverSubscriptionEventJob.perform_now("pull_request", pull_request_payload(action: "review_requested", reviewer: "kevin-gh", number: 14))
    end

    # The messages still post; only the inbox items are skipped.
    assert_equal 2, @room.messages.where("markdown_source LIKE ?", "%requested a review%").count
  end

  test "team review requests post nothing" do
    assert_no_difference -> { @room.messages.count } do
      payload = pull_request_payload(action: "review_requested")
      payload.delete("requested_reviewer")
      payload["requested_team"] = { "name" => "rails-core" }
      Github::DeliverSubscriptionEventJob.perform_now("pull_request", payload)
    end
  end

  test "review_submitted posts each review once" do
    Github::DeliverSubscriptionEventJob.perform_now("pull_request_review", review_payload(state: "approved", id: 7))

    message = @room.messages.order(:created_at).last
    assert_equal "**carol** approved #12: Fix login\nhttps://github.com/rails/rails/pull/12", message.markdown_source

    assert_no_difference -> { @room.messages.count } do
      Github::DeliverSubscriptionEventJob.perform_now("pull_request_review", review_payload(state: "approved", id: 7))
    end

    Github::DeliverSubscriptionEventJob.perform_now("pull_request_review", review_payload(state: "changes_requested", id: 8))
    assert_equal "**carol** requested changes on #12: Fix login\nhttps://github.com/rails/rails/pull/12",
      @room.messages.order(:created_at).last.markdown_source

    Github::DeliverSubscriptionEventJob.perform_now("pull_request_review", review_payload(state: "commented", id: 9))
    assert_equal "**carol** commented on #12: Fix login\nhttps://github.com/rails/rails/pull/12",
      @room.messages.order(:created_at).last.markdown_source
  end

  test "three check failures on one sha post once, a new sha posts again" do
    assert_difference -> { @room.messages.count }, 1 do
      Github::DeliverSubscriptionEventJob.perform_now("check_run", check_run_payload(name: "ci / test"))
      Github::DeliverSubscriptionEventJob.perform_now("check_run", check_run_payload(name: "ci / lint"))
      Github::DeliverSubscriptionEventJob.perform_now("check_suite", check_suite_payload)
    end

    message = @room.messages.order(:created_at).last
    assert_equal "Checks failed on #12 (`ci / test`)\nhttps://github.com/rails/rails/pull/12", message.markdown_source

    assert_difference -> { @room.messages.count }, 1 do
      Github::DeliverSubscriptionEventJob.perform_now("check_run", check_run_payload(name: "ci / test", sha: "def456"))
    end
  end

  test "successful checks post nothing" do
    assert_no_difference -> { @room.messages.count } do
      Github::DeliverSubscriptionEventJob.perform_now("check_run", check_run_payload(conclusion: "success"))
      Github::DeliverSubscriptionEventJob.perform_now("check_suite", check_suite_payload(conclusion: "success"))
    end
  end

  test "failed status posts for the stored pr on that branch" do
    pull_request = Github::PullRequest.for_reference(owner: "rails", repo: "rails", number: 12)
    pull_request.update!(head_branch: "shiny", title: "Fix login", html_url: "https://github.com/rails/rails/pull/12")

    Github::DeliverSubscriptionEventJob.perform_now("status", status_payload(state: "failure"))

    message = @room.messages.order(:created_at).last
    assert_equal "Checks failed on #12: Fix login (`ci / test`)\nhttps://github.com/rails/rails/pull/12", message.markdown_source
  end

  test "failed status without a stored pr posts nothing" do
    assert_no_difference -> { @room.messages.count } do
      Github::DeliverSubscriptionEventJob.perform_now("status", status_payload(state: "failure"))
      Github::DeliverSubscriptionEventJob.perform_now("status", status_payload(state: "success"))
    end
  end

  test "unsubscribed event keys post nothing" do
    @subscription.update!(events: %w[ opened ])

    assert_no_difference -> { @room.messages.count } do
      Github::DeliverSubscriptionEventJob.perform_now("pull_request", pull_request_payload(action: "closed", merged: true))
      Github::DeliverSubscriptionEventJob.perform_now("check_run", check_run_payload)
    end

    assert_no_difference -> { Github::Notification.count } do
      Github::DeliverSubscriptionEventJob.perform_now("pull_request", pull_request_payload(action: "closed", merged: true))
    end
  end

  test "unsubscribed repositories post nothing and create no bot user" do
    Github::RepositorySubscription.delete_all
    User.active_bots.where(name: "GitHub").delete_all

    assert_no_difference [ -> { Message.count }, -> { Github::Notification.count }, -> { User.count } ] do
      Github::DeliverSubscriptionEventJob.perform_now("pull_request", pull_request_payload(action: "opened"))
    end
  end

  test "unhandled events post nothing" do
    assert_no_difference -> { @room.messages.count } do
      Github::DeliverSubscriptionEventJob.perform_now("ping", {})
      Github::DeliverSubscriptionEventJob.perform_now("push", { "repository" => { "full_name" => "rails/rails" } })
    end
  end

  test "posted messages broadcast to the room like any other message" do
    stream = room_messages_stream_name(@room)

    assert_broadcasts stream, 1 do
      Github::DeliverSubscriptionEventJob.perform_now("pull_request", pull_request_payload(action: "opened"))
    end
  end

  test "claimed notifications record their message" do
    Github::DeliverSubscriptionEventJob.perform_now("pull_request", pull_request_payload(action: "opened"))

    notification = Github::Notification.find_by!(subscription: @subscription, dedupe_key: "opened:rails/rails#12")
    assert_equal @room.messages.order(:created_at).last, notification.message
  end

  test "an event posts a thread reply where the PR has a thread and a room message elsewhere" do
    other_room = rooms(:watercooler)
    Github::RepositorySubscription.create!(
      room: other_room, owner: "rails", repo: "rails",
      events: %w[ opened ], created_by: users(:david))

    thread = discuss_pull_request(@room, number: 12, client_id: "notifier-thread-parent")
    thread.update_column(:last_activity_at, 2.days.ago)

    Github::DeliverSubscriptionEventJob.perform_now("pull_request", pull_request_payload(action: "opened"))

    bot = User.active_bots.find_by!(name: "GitHub")
    reply = thread.messages.order(:created_at).last
    assert_equal bot, reply.creator
    assert_equal "**alice** opened pull request #12: Fix login\nhttps://github.com/rails/rails/pull/12", reply.markdown_source
    assert_empty @room.root_messages.where(creator: bot)

    room_message = other_room.messages.order(:created_at).last
    assert_equal bot, room_message.creator
    assert_nil room_message.thread_id
    assert_equal reply.markdown_source, room_message.markdown_source

    assert_operator thread.reload.last_activity_at, :>, 2.days.ago
  end

  test "thread updates dedupe like room messages" do
    thread = discuss_pull_request(@room, number: 12, client_id: "notifier-thread-dedupe")

    Github::DeliverSubscriptionEventJob.perform_now("pull_request", pull_request_payload(action: "opened"))

    assert_no_difference -> { thread.messages.count } do
      Github::DeliverSubscriptionEventJob.perform_now("pull_request", pull_request_payload(action: "reopened"))
    end
  end

  test "review_requested in a PR thread points the inbox item at the thread message" do
    users(:kevin).update!(github_login: "kevin-gh")
    thread = discuss_pull_request(@room, number: 12, client_id: "notifier-thread-review")

    Github::DeliverSubscriptionEventJob.perform_now("pull_request", pull_request_payload(action: "review_requested", reviewer: "Kevin-GH"))

    reply = thread.messages.order(:created_at).last
    assert_equal "**bob** requested a review from **Kevin-GH** on #12: Fix login\nhttps://github.com/rails/rails/pull/12", reply.markdown_source

    item = ActivityItem.find_by!(user: users(:kevin), event_type: "pr_review_request")
    assert_equal reply, item.source
    assert_includes ActivityItem.accessible_to(users(:kevin)), item
  end

  test "an update for a locked PR thread falls back to a root room message" do
    thread = discuss_pull_request(@room, number: 12, client_id: "notifier-thread-locked")
    thread.lock_conversation!

    assert_difference -> { @room.root_messages.count }, 1 do
      assert_no_difference -> { thread.messages.count } do
        Github::DeliverSubscriptionEventJob.perform_now("pull_request", pull_request_payload(action: "opened"))
      end
    end

    bot = User.active_bots.find_by!(name: "GitHub")
    message = @room.root_messages.order(:created_at).last
    assert_equal bot, message.creator
    assert_equal "**alice** opened pull request #12: Fix login\nhttps://github.com/rails/rails/pull/12", message.markdown_source
    assert_predicate thread.reload, :locked?
  end

  test "an update for a closed PR thread still lands in the thread" do
    thread = discuss_pull_request(@room, number: 12, client_id: "notifier-thread-closed")
    thread.close!

    assert_difference -> { thread.messages.count }, 1 do
      Github::DeliverSubscriptionEventJob.perform_now("pull_request", pull_request_payload(action: "opened"))
    end

    bot = User.active_bots.find_by!(name: "GitHub")
    assert_empty @room.root_messages.where(creator: bot)
    assert_predicate thread.reload, :active?
    reply = thread.messages.order(:created_at).last
    assert_equal "**alice** opened pull request #12: Fix login\nhttps://github.com/rails/rails/pull/12", reply.markdown_source
  end

  test "subscription events find the PR thread regardless of payload case" do
    thread = discuss_pull_request(@room, number: 12, client_id: "notifier-thread-case")
    payload = pull_request_payload(action: "opened")
    payload["repository"]["full_name"] = "Rails/Rails"
    payload["pull_request"]["base"]["repo"]["full_name"] = "Rails/Rails"

    assert_difference -> { thread.messages.count }, 1 do
      Github::DeliverSubscriptionEventJob.perform_now("pull_request", payload)
    end

    bot = User.active_bots.find_by!(name: "GitHub")
    assert_empty @room.root_messages.where(creator: bot)
  end

  test "failed checks use the stored title regardless of payload case" do
    pull_request = Github::PullRequest.for_reference(owner: "rails", repo: "rails", number: 12)
    pull_request.update!(title: "Fix login")
    payload = check_run_payload(name: "ci / test")
    payload["repository"]["full_name"] = "Rails/Rails"

    Github::DeliverSubscriptionEventJob.perform_now("check_run", payload)

    message = @room.messages.order(:created_at).last
    assert_equal "Checks failed on #12: Fix login (`ci / test`)\nhttps://github.com/Rails/Rails/pull/12", message.markdown_source
  end

  test "failed status matches stored PRs regardless of payload case" do
    pull_request = Github::PullRequest.for_reference(owner: "rails", repo: "rails", number: 12)
    pull_request.update!(head_branch: "shiny", title: "Fix login", html_url: "https://github.com/rails/rails/pull/12")
    payload = status_payload(state: "failure")
    payload["repository"]["full_name"] = "Rails/Rails"

    Github::DeliverSubscriptionEventJob.perform_now("status", payload)

    message = @room.messages.order(:created_at).last
    assert_equal "Checks failed on #12: Fix login (`ci / test`)\nhttps://github.com/rails/rails/pull/12", message.markdown_source
  end

  test "thread updates broadcast to the thread stream" do
    thread = discuss_pull_request(@room, number: 12, client_id: "notifier-thread-broadcast")
    stream = thread_messages_stream_name(thread)

    assert_broadcasts stream, 1 do
      Github::DeliverSubscriptionEventJob.perform_now("pull_request", pull_request_payload(action: "opened"))
    end
  end

  private
    def discuss_pull_request(room, number:, client_id:)
      parent = room.messages.create!(
        creator: users(:david),
        markdown_source: "review https://github.com/Rails/Rails/pull/#{number}",
        client_message_id: client_id
      )
      pull_request = parent.github_pull_requests.first
      thread = ChannelThread.create!(room: room, creator: users(:david), name: "PR chat", parent_message: parent)
      ThreadMembership.join!(thread, users(:david))
      Github::PullRequestThread.create!(pull_request: pull_request, room: room, channel_thread: thread)
      thread
    end

    def thread_messages_stream_name(thread)
      signed = Turbo::StreamsChannel.signed_stream_name([ thread, :messages ])
      Turbo::StreamsChannel.verified_stream_name(signed)
    end
    def pull_request_payload(action:, number: 12, title: "Fix login", merged: false, reviewer: "carol")
      {
        "action" => action,
        "sender" => { "login" => action == "review_requested" ? "bob" : "alice" },
        "repository" => { "full_name" => "rails/rails" },
        "pull_request" => {
          "number" => number,
          "title" => title,
          "html_url" => "https://github.com/rails/rails/pull/#{number}",
          "merged" => merged,
          "merged_by" => { "login" => "alice" },
          "closed_at" => "2026-09-17T12:00:00Z",
          "base" => { "repo" => { "full_name" => "rails/rails" } }
        },
        "requested_reviewer" => { "login" => reviewer }
      }
    end

    def review_payload(state:, id:)
      {
        "action" => "submitted",
        "sender" => { "login" => "carol" },
        "repository" => { "full_name" => "rails/rails" },
        "review" => { "id" => id, "state" => state, "user" => { "login" => "carol" } },
        "pull_request" => {
          "number" => 12,
          "title" => "Fix login",
          "html_url" => "https://github.com/rails/rails/pull/12",
          "base" => { "repo" => { "full_name" => "rails/rails" } }
        }
      }
    end

    def check_run_payload(conclusion: "failure", sha: "abc123", name: "ci / test", numbers: [ 12 ])
      {
        "action" => "completed",
        "repository" => { "full_name" => "rails/rails" },
        "check_run" => {
          "name" => name,
          "head_sha" => sha,
          "conclusion" => conclusion,
          "pull_requests" => numbers.map { |number| { "number" => number } }
        }
      }
    end

    def check_suite_payload(conclusion: "failure", sha: "abc123", numbers: [ 12 ])
      {
        "action" => "completed",
        "repository" => { "full_name" => "rails/rails" },
        "check_suite" => {
          "head_sha" => sha,
          "conclusion" => conclusion,
          "pull_requests" => numbers.map { |number| { "number" => number } },
          "app" => { "name" => "CI" }
        }
      }
    end

    def status_payload(state:, sha: "abc123", branches: [ "shiny" ])
      {
        "state" => state,
        "sha" => sha,
        "context" => "ci / test",
        "repository" => { "full_name" => "rails/rails" },
        "branches" => branches.map { |name| { "name" => name } }
      }
    end

    def room_messages_stream_name(room)
      signed = Turbo::StreamsChannel.signed_stream_name([ room, :messages ])
      Turbo::StreamsChannel.verified_stream_name(signed)
    end
end
