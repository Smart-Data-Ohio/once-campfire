require "test_helper"

class ChannelThreadsBoardTest < ActionDispatch::IntegrationTest
  setup do
    @room = Rooms::Board.create_for({ name: "Launch", creator: users(:david) },
      users: [ users(:david), users(:jz), users(:kevin) ])
    @creator = users(:jz)
    @post = ChannelThread.create!(room: @room, creator: @creator, name: "Ship it", work_status: "planned")
    ThreadMembership.join!(@post, @creator)
  end

  test "new post form renders in boards and 404s in channels and for non-members" do
    sign_in :jz
    get new_room_thread_url(@room)
    assert_response :success
    assert_select "form[action='#{room_threads_path(@room)}']"

    get new_room_thread_url(rooms(:designers))
    assert_response :not_found

    sign_in :jason
    assert_raises ActiveRecord::RecordNotFound do
      get new_room_thread_url(@room)
    end
  end

  test "creates a post with a first message, owner, status, and tags" do
    sign_in :jz

    assert_difference -> { ChannelThread.count }, 1 do
      assert_difference -> { Message.thread_messages.count }, 1 do
        post room_threads_url(@room), params: {
          thread: { name: "Launch checklist", work_status: "in_progress",
            work_owner_id: users(:kevin).id, tags: "Launch, api",
            first_message: "The brief for launch." }
        }
      end
    end

    post = ChannelThread.ordered.first
    assert_redirected_to room_thread_path(@room, post)
    assert_equal "Launch checklist", post.name
    assert_equal "in_progress", post.work_status
    assert_equal users(:kevin).id, post.work_owner_id
    assert_equal %w[ api launch ], post.tag_names
    assert_equal "The brief for launch.", post.messages.sole.plain_text_body
    assert_equal @creator.id, post.creator_id
  end

  test "creates a post without a first message and defaults to planned" do
    sign_in :jz

    assert_difference -> { ChannelThread.count }, 1 do
      assert_no_difference -> { Message.count } do
        post room_threads_url(@room, format: :json), params: {
          thread: { name: "Messageless post", first_message: "  " }
        }
      end
    end

    assert_response :created
    post = ChannelThread.find(response.parsed_body.dig("thread", "id"))
    assert_equal "planned", post.work_status
    assert_nil post.work_owner_id
    assert_empty post.messages
  end

  test "creates a post with an agent owner through the assignment path" do
    agent_user = User.create_bot!(name: "Board Worker")
    agent = agent_user.create_agent!(kind: :workspace, owner: users(:david))
    @room.memberships.grant_to(agent_user)
    AgentGrant.create!(agent: agent, room: @room, granted_by: users(:david), capability: "post_messages")

    sign_in :jz
    assert_difference -> { agent.agent_events.where(event_type: "work_assigned").count }, 1 do
      post room_threads_url(@room, format: :json), params: {
        thread: { name: "Agent post", work_owner_id: agent_user.id }
      }
    end

    assert_response :created
    post = ChannelThread.find(response.parsed_body.dig("thread", "id"))
    assert_equal agent_user.id, post.work_owner_id
    assert_equal "work_assignment", post.work_thread_events.ordered.first.event_type
  end

  test "rejects posts with invalid titles, owners, statuses, and tags" do
    sign_in :jz

    assert_no_difference -> { ChannelThread.count } do
      post room_threads_url(@room), params: { thread: { name: "", first_message: "No title" } }
    end
    assert_response :unprocessable_entity
    assert_match "Name can&#39;t be blank", response.body

    assert_no_difference -> { ChannelThread.count } do
      post room_threads_url(@room, format: :json), params: {
        thread: { name: "Bad owner", work_owner_id: users(:jason).id }
      }
    end
    assert_response :unprocessable_entity

    assert_no_difference -> { ChannelThread.count } do
      post room_threads_url(@room, format: :json), params: {
        thread: { name: "Bad status", work_status: "shipping" }
      }
    end
    assert_response :unprocessable_entity

    assert_no_difference -> { ChannelThread.count } do
      post room_threads_url(@room, format: :json), params: {
        thread: { name: "Bad tags", tags: "one, two, three, four, five, six" }
      }
    end
    assert_response :unprocessable_entity
  end

  test "non-members cannot create posts" do
    sign_in :jason

    assert_no_difference -> { ChannelThread.count } do
      assert_raises ActiveRecord::RecordNotFound do
        post room_threads_url(@room, format: :json), params: { thread: { name: "Intruder" } }
      end
    end
  end

  test "a new post notifies everything-followers and always the human owner" do
    @room.memberships.grant_to(users(:jason))
    @room.memberships.find_by!(user: users(:jason)).update!(involvement: "everything")
    @room.memberships.find_by!(user: users(:kevin)).update!(involvement: "nothing")

    sign_in :jz
    post room_threads_url(@room), params: {
      thread: { name: "Notified post", work_owner_id: users(:kevin).id, first_message: "Read me." }
    }

    post = ChannelThread.ordered.first
    assert_equal 1, ActivityItem.where(user: users(:jason), event_type: "thread_activity").count
    assert_equal post.messages.sole.id, ActivityItem.find_by!(user: users(:jason)).source_id
    assert_equal 1, ActivityItem.where(user: users(:kevin), event_type: "thread_activity").count
    assert_empty ActivityItem.where(user: @creator)
  end

  test "a messageless post creates no inbox items but marks the board unread" do
    sign_in :jz
    post room_threads_url(@room, format: :json), params: { thread: { name: "Quiet post" } }
    assert_response :created

    assert_empty ActivityItem.all
    assert @room.memberships.find_by!(user: users(:kevin)).unread?
    assert @room.memberships.find_by!(user: users(:david)).unread?
    assert_not @room.memberships.find_by!(user: @creator).unread?
  end

  test "post owner, creator, board creator, and admins can change the status" do
    @post.update!(work_owner_id: users(:kevin).id)

    { kevin: "in_progress", jz: "blocked", david: "done" }.each do |user, status|
      sign_in user
      patch room_thread_url(@room, @post, format: :json), params: { thread: { work_status: status } }
      assert_response :success
      assert_equal status, @post.reload.work_status
    end

    @post.update!(work_owner_id: users(:jz).id)
    sign_in :kevin
    patch room_thread_url(@room, @post, format: :json), params: { thread: { work_status: "planned" } }
    assert_response :forbidden
    assert_equal "done", @post.reload.work_status
  end

  test "post creator, board creator, and admins can assign the owner" do
    sign_in :jz
    patch room_thread_url(@room, @post, format: :json), params: { thread: { work_owner_id: users(:kevin).id } }
    assert_response :success
    assert_equal users(:kevin).id, @post.reload.work_owner_id

    sign_in :david
    patch room_thread_url(@room, @post, format: :json), params: { thread: { work_owner_id: "" } }
    assert_response :success
    assert_nil @post.reload.work_owner_id

    @post.update!(work_owner_id: users(:kevin).id)
    sign_in :kevin
    patch room_thread_url(@room, @post, format: :json), params: { thread: { work_owner_id: users(:jz).id } }
    assert_response :forbidden
    assert_equal users(:kevin).id, @post.reload.work_owner_id
  end

  test "the owning agent can change the status but cannot reassign" do
    agent = agents(:bender_agent)
    @room.memberships.grant_to(users(:bender))
    AgentGrant.create!(agent: agent, room: @room, granted_by: users(:david), capability: "post_messages")
    AgentGrant.create!(agent: agent, room: @room, granted_by: users(:david), capability: "manage_threads")
    @post.update_work!(actor: @creator, work_owner_id: users(:bender).id)
    headers = { "Authorization" => "Bearer bender-test-secret-1234", "Content-Type" => "application/json" }

    patch "/agents/work/#{@post.id}", headers: headers,
      params: { work_status: "in_progress", work_owner_id: users(:kevin).id }.to_json
    assert_response :success
    assert_equal "in_progress", @post.reload.work_status
    assert_equal users(:bender).id, @post.reload.work_owner_id
  end

  test "the owning agent without manage_threads cannot change the status" do
    agent = agents(:bender_agent)
    @room.memberships.grant_to(users(:bender))
    AgentGrant.create!(agent: agent, room: @room, granted_by: users(:david), capability: "post_messages")
    @post.update_work!(actor: @creator, work_owner_id: users(:bender).id)
    headers = { "Authorization" => "Bearer bender-test-secret-1234", "Content-Type" => "application/json" }

    patch "/agents/work/#{@post.id}", headers: headers, params: { work_status: "in_progress" }.to_json
    assert_response :forbidden
    assert_equal "planned", @post.reload.work_status
  end

  test "post owner can edit the title and tags like the status managers" do
    @post.update!(work_owner_id: users(:kevin).id)

    sign_in :kevin
    patch room_thread_url(@room, @post, format: :json), params: { thread: { name: "Renamed", tags: "renamed, api" } }
    assert_response :success
    assert_equal "Renamed", @post.reload.name
    assert_equal %w[ api renamed ], @post.tag_names

    @post.update!(work_owner_id: users(:jz).id)
    sign_in :kevin
    patch room_thread_url(@room, @post, format: :json), params: { thread: { name: "Hijacked", tags: "hijack" } }
    assert_response :forbidden
    assert_equal "Renamed", @post.reload.name

    patch room_thread_url(@room, @post, format: :json), params: { thread: { tags: "hijack" } }
    assert_response :forbidden
    assert_equal %w[ api renamed ], @post.reload.tag_names
  end

  test "result edits follow the status rule and write a result_updated event" do
    @post.update!(work_owner_id: users(:kevin).id)

    sign_in :kevin
    assert_difference -> { @post.work_thread_events.where(event_type: "result_updated").count }, 1 do
      patch room_thread_url(@room, @post), params: { thread: { result_markdown: "## Outcome" } }
    end
    assert_redirected_to room_thread_path(@room, @post)
    assert_equal "## Outcome", @post.reload.result_markdown

    get room_thread_url(@room, @post)
    assert_response :success
    assert_select ".board-post__result-body", text: /Outcome/
    assert_select ".board-post__history", text: /Kevin updated the result/

    @post.update!(work_owner_id: users(:jz).id)
    sign_in :kevin
    patch room_thread_url(@room, @post, format: :json), params: { thread: { result_markdown: "Hijacked" } }
    assert_response :forbidden
    assert_equal "## Outcome", @post.reload.result_markdown
  end

  test "stopping work tracking is rejected for posts" do
    sign_in :jz
    patch room_thread_url(@room, @post, format: :json), params: { thread: { work_status: "", work_owner_id: "" } }
    assert_response :unprocessable_entity
    assert_equal "planned", @post.reload.work_status

    @post.update!(work_owner_id: users(:kevin).id)
    sign_in :kevin
    patch room_thread_url(@room, @post, format: :json), params: { thread: { work_status: "" } }
    assert_response :forbidden
    assert_equal "planned", @post.reload.work_status
  end

  test "auto-archive changes are rejected for posts" do
    sign_in :jz
    patch room_thread_url(@room, @post, format: :json), params: { thread: { auto_archive_after_minutes: 60 } }
    assert_response :unprocessable_entity
    assert_match "not available for board posts", response.parsed_body.fetch("error")
    assert_equal ChannelThread::DEFAULT_AUTO_ARCHIVE_AFTER_MINUTES, @post.reload.auto_archive_after_minutes
  end

  test "only the board creator and admins can close, lock, or delete a post" do
    sign_in :jz
    patch room_thread_url(@room, @post, format: :json), params: { thread: { status: "closed" } }
    assert_response :forbidden
    assert_predicate @post.reload, :active?

    sign_in :david
    patch room_thread_url(@room, @post, format: :json), params: { thread: { status: "closed" } }
    assert_response :success
    assert_predicate @post.reload, :closed?

    patch room_thread_url(@room, @post, format: :json), params: { thread: { status: "locked" } }
    assert_response :success
    assert_predicate @post.reload, :locked?

    sign_in :kevin
    delete room_thread_url(@room, @post, format: :json)
    assert_response :forbidden

    sign_in :david
    delete room_thread_url(@room, @post, format: :json)
    assert_response :no_content
    assert_not ChannelThread.exists?(@post.id)
  end

  test "members can reply in a post and join or leave it from the page" do
    sign_in :kevin
    post room_thread_messages_url(@room, @post, format: :json), params: {
      message: { markdown_source: "A member reply", client_message_id: "board-reply" }
    }
    assert_response :created
    assert_equal "A member reply", @post.messages.sole.plain_text_body

    post join_room_thread_url(@room, @post)
    assert_redirected_to room_thread_path(@room, @post)
    assert @post.memberships.exists?(user: users(:kevin))

    delete leave_room_thread_url(@room, @post)
    assert_redirected_to room_thread_path(@room, @post)
    assert_not @post.memberships.exists?(user: users(:kevin))

    sign_in :jason
    assert_raises ActiveRecord::RecordNotFound do
      post room_thread_messages_url(@room, @post, format: :json), params: {
        message: { markdown_source: "An intruder reply", client_message_id: "board-intruder" }
      }
    end
  end

  test "any member can link and unlink but non-members cannot" do
    sign_in :kevin
    post thread_work_links_url(@post), params: {
      kind: "drive_file", drive_url: "https://drive.google.com/file/d/board1234567"
    }
    assert_redirected_to room_thread_path(@room, @post)
    link = @post.reload.work_thread_links.sole
    assert_predicate link, :drive_file?
    assert_equal "https://drive.google.com/file/d/board1234567", link.url

    get room_thread_url(@room, @post)
    assert_response :success
    assert_match "drive.google.com", response.body

    delete thread_work_link_url(@post, link)
    assert_redirected_to room_thread_path(@room, @post)
    assert_empty @post.reload.work_thread_links

    sign_in :jason
    post thread_work_links_url(@post), params: {
      kind: "drive_file", drive_url: "https://drive.google.com/file/d/board4567890"
    }
    assert_response :not_found
    assert_empty @post.reload.work_thread_links
  end

  test "board page renders the list with rows, filters, and a new-post link" do
    @post.update!(work_owner_id: users(:kevin).id)
    @post.tag_names = "api, launch"
    @post.save!
    @post.post_message!(creator: @creator, attributes: { markdown_source: "First", client_message_id: "row-first" })
    done = ChannelThread.create!(room: @room, creator: @creator, name: "Finished", work_status: "done")
    ThreadMembership.join!(done, @creator)

    sign_in :jz
    get room_url(@room)
    assert_response :success
    assert_select "#board_posts .board-row", count: 1
    assert_select "##{ActionView::RecordIdentifier.dom_id(@post, :board_row)}", text: /Ship it/
    assert_select ".board-row__status", text: "Planned"
    assert_select ".board-row__owner", text: /Kevin/
    assert_select ".board-tag", text: "api"
    assert_select ".board-row__meta", text: /1 reply/
    assert_select "a[href='#{new_room_thread_path(@room)}']", text: "New post"

    get room_url(@room, status: "done")
    assert_select "#board_posts .board-row", count: 1
    assert_select "##{ActionView::RecordIdentifier.dom_id(done, :board_row)}"

    get room_url(@room, status: "all", owner: "me")
    assert_select "#board_posts .board-row", count: 0

    get room_url(@room, status: "all", owner: users(:kevin).id)
    assert_select "#board_posts .board-row", count: 1

    get room_url(@room, status: "all", tag: "launch")
    assert_select "#board_posts .board-row", count: 1

    get room_url(@room, status: "all", tag: "missing")
    assert_select "#board_posts .board-row", count: 0
  end

  test "board index pages at fifty posts with a load more link" do
    55.times do |index|
      ChannelThread.create!(room: @room, creator: @creator, name: "Paged #{index}", work_status: "planned")
    end

    sign_in :jz
    get room_url(@room)
    assert_response :success
    assert_select "#board_posts .board-row", count: 50
    load_more = css_select("p.board__more a").sole
    assert_equal "Load more", load_more.text.strip
    assert_includes load_more["href"], "page=2"

    get room_url(@room, page: 2)
    assert_response :success
    assert_select "#board_posts .board-row", count: 56
    assert_select "p.board__more", count: 0

    get room_url(@room, view: "board")
    assert_response :success
    assert_select ".board__column-list .board-row", count: 50
    assert_select "p.board__more a", text: "Load more", count: 1
  end

  test "board rows and containers carry filter data for live updates" do
    @post.update!(work_owner_id: users(:kevin).id)
    @post.tag_names = "api, launch"
    @post.save!

    sign_in :jz
    get room_url(@room, status: "all", owner: users(:kevin).id, tag: "api")
    assert_response :success
    assert_select "#board_posts[data-controller='board-list'][data-board-list-status-value='all']" \
      "[data-board-list-owner-value='#{users(:kevin).id}'][data-board-list-tag-value='api']" \
      "[data-board-list-current-user-id-value='#{users(:jz).id}']"
    assert_select "##{ActionView::RecordIdentifier.dom_id(@post, :board_row)}" \
      "[data-board-row][data-status='planned'][data-owner-id='#{users(:kevin).id}']" \
      "[data-owner-agent='false'][data-tags='api launch']"

    get room_url(@room, view: "board")
    assert_response :success
    assert_select ".board__columns[data-controller='board-list'][data-board-list-status-value='all']"
  end

  test "rendering the board index costs no extra queries per post" do
    create_board_posts(2, offset: 0)

    sign_in :jz
    # Warm per-process caches (the workspace icon registry's version stamp)
    # so the two measured renders share the same constant cold-cache cost.
    get room_url(@room)
    assert_response :success

    small = count_board_queries { get room_url(@room) }
    assert_response :success
    assert_select "#board_posts .board-row", count: 3

    create_board_posts(4, offset: 10)

    large = count_board_queries { get room_url(@room) }
    assert_response :success
    assert_select "#board_posts .board-row", count: 7

    assert_equal small, large,
      "board render should be O(1) in queries, got #{small} then #{large}"
  end

  test "board rendering groups posts into read-only status columns" do
    @post.update!(work_status: "in_progress")
    done = ChannelThread.create!(room: @room, creator: @creator, name: "Finished", work_status: "done")
    ThreadMembership.join!(done, @creator)

    sign_in :jz
    get room_url(@room, view: "board")
    assert_response :success
    assert_select ".board__column", count: 4
    assert_select ".board__column[aria-label='In progress'] ##{ActionView::RecordIdentifier.dom_id(@post, :board_column_row)}"
    assert_select ".board__column[aria-label='Done'] ##{ActionView::RecordIdentifier.dom_id(done, :board_column_row)}"
    assert_select "#board_column_in_progress ##{ActionView::RecordIdentifier.dom_id(@post, :board_column_row)}"
    assert_select "#board_column_done ##{ActionView::RecordIdentifier.dom_id(done, :board_column_row)}"
    assert_select ".board__column[aria-label='Planned'] .board-row", count: 0
    assert_select "form.board__filters select[name='status']", count: 0

    get room_url(@room, view: "board", status: "done")
    assert_select ".board__column[aria-label='In progress'] .board-row", count: 1
  end

  test "post page shows the board header, result, and manage controls without tracking controls" do
    @post.update!(result_markdown: "## Outcome", result_updated_at: Time.current, result_updated_by_id: @creator.id)
    @post.update!(run_url: "https://example.test/runs/1")

    sign_in :david
    get room_thread_url(@room, @post)
    assert_response :success
    assert_select ".board-post__header h1", text: "Ship it"
    assert_select ".board-post__work", text: /Planned/
    assert_select ".board-post__result-body", text: /Outcome/
    assert_select ".board-post__run a[href='https://example.test/runs/1'][rel='noopener noreferrer']", text: "Run"
    assert_select ".board-post__manage"
    assert_no_match "Stop tracking work", response.body
    assert_no_match "Auto-close after", response.body
  end

  test "a status change replaces the list row and moves the column row" do
    @post.update!(work_owner_id: users(:kevin).id)

    sign_in :jz
    patch room_thread_url(@room, @post, format: :json), params: { thread: { work_status: "in_progress" } }
    assert_response :success

    assert_rendered_turbo_stream_broadcast @room, :messages, action: "replace", target: [ @post, :board_row ] do
      assert_select ".board-row__status", text: "In progress"
    end

    column_row_id = ActionView::RecordIdentifier.dom_id(@post, :board_column_row)
    streams = capture_turbo_stream_broadcasts([ @room, :messages ])
    assert streams.any? { |stream| stream["action"] == "remove" && stream["target"] == column_row_id },
      "expected the stale column row to be removed"
    move = streams.find { |stream| stream["action"] == "prepend" && stream["target"] == "board_column_in_progress" }
    assert move, "expected a prepend into the new status column"
    assert_includes move.to_html, column_row_id
    assert_match "Ship it", move.to_html
  end

  test "a new post prepends into the board list and its status column" do
    sign_in :jz
    post room_threads_url(@room, format: :json), params: { thread: { name: "Prepended post" } }
    assert_response :created

    post = ChannelThread.find(response.parsed_body.dig("thread", "id"))
    streams = capture_turbo_stream_broadcasts([ @room, :messages ])
    prepend = streams.find do |stream|
      stream["action"] == "prepend" && stream.to_html.include?(ActionView::RecordIdentifier.dom_id(post, :board_row))
    end
    assert_equal "board_posts", prepend["target"]
    assert_match "Prepended post", prepend.to_html

    column_prepend = streams.find do |stream|
      stream["action"] == "prepend" && stream.to_html.include?(ActionView::RecordIdentifier.dom_id(post, :board_column_row))
    end
    assert column_prepend, "expected a prepend of the new post into its status column"
    assert_equal "board_column_planned", column_prepend["target"]
    assert_match "Prepended post", column_prepend.to_html
  end

  test "a tag change replaces the post row over the room stream" do
    sign_in :jz
    patch room_thread_url(@room, @post, format: :json), params: { thread: { tags: "shiny" } }
    assert_response :success

    assert_rendered_turbo_stream_broadcast @room, :messages, action: "replace", target: [ @post, :board_row ] do
      assert_select ".board-tag", text: "shiny"
    end
    assert_rendered_turbo_stream_broadcast @room, :messages, action: "replace", target: [ @post, :board_column_row ] do
      assert_select ".board-tag", text: "shiny"
    end
  end

  test "deleting a post removes its rows instead of re-rendering them" do
    @post.tag_names = "doomed"
    @post.save!

    sign_in :david
    ActionCable.server.pubsub.clear
    delete room_thread_url(@room, @post, format: :json)
    assert_response :no_content

    streams = capture_turbo_stream_broadcasts([ @room, :messages ])
    removes = streams.select { |stream| stream["action"] == "remove" }
    assert_equal [
      ActionView::RecordIdentifier.dom_id(@post, :board_row),
      ActionView::RecordIdentifier.dom_id(@post, :board_column_row)
    ].to_set, removes.map { |stream| stream["target"] }.to_set
    assert streams.none? { |stream| stream["action"] == "replace" },
      "destroyed tags must not re-render the deleted row"
  end

  test "deleting a channel thread broadcasts no board row remove" do
    thread = ChannelThread.create!(room: rooms(:designers), creator: users(:david), name: "Ordinary")

    sign_in :david
    ActionCable.server.pubsub.clear
    delete room_thread_url(rooms(:designers), thread, format: :json)
    assert_response :no_content

    streams = capture_turbo_stream_broadcasts([ rooms(:designers), :messages ])
    assert_empty streams
  end

  test "bot posting API returns 422 in a board" do
    @room.memberships.grant_to(users(:bender))

    post room_bot_messages_url(@room, users(:bender).bot_key), params: +"Board root message"
    assert_response :unprocessable_entity
    assert_empty @room.root_messages

    post room_bot_messages_url(rooms(:watercooler), users(:bender).bot_key), params: +"Channel root message"
    assert_response :created
  end

  private
    def create_board_posts(count, offset:)
      count.times do |index|
        number = offset + index
        post = ChannelThread.create!(room: @room, creator: @creator,
          name: "Query post #{number}", work_status: "planned",
          work_owner_id: (number.even? ? users(:kevin).id : @creator.id))
        post.tag_names = "query, probe-#{number}"
        post.save!
        post.post_message!(creator: @creator, attributes: {
          markdown_source: "Reply #{number}", client_message_id: "board-query-#{number}"
        })
        WorkThreadLink.create!(channel_thread: post, kind: "drive_file",
          url: "https://drive.google.com/file/d/boardquery#{number}", created_by: @creator)
      end
    end

    # Same shape as the count_queries in GithubPrCardsTest: every SQL
    # statement except schema loads and query-cache hits.
    def count_board_queries
      count = 0
      subscription = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        count += 1 unless payload[:name] == "SCHEMA" || payload[:cached]
      end

      ActiveRecord::Base.connection.clear_query_cache
      yield
      count
    ensure
      ActiveSupport::Notifications.unsubscribe(subscription)
    end
end
