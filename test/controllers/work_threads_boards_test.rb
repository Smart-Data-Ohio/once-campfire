require "test_helper"

class WorkThreadsBoardsTest < ActionDispatch::IntegrationTest
  setup do
    @room = rooms(:designers)
    @board = Rooms::Board.create_for({ name: "Launch", creator: users(:david) },
      users: [ users(:david), users(:jz) ])

    @channel_work = ChannelThread.create!(room: @room, creator: users(:jz), name: "Channel work")
    ThreadMembership.join!(@channel_work, users(:jz))
    @channel_work.update!(work_status: "in_progress", work_owner_id: users(:kevin).id)

    @board_post = ChannelThread.create!(room: @board, creator: users(:jz), name: "Board post", work_status: "planned")
    ThreadMembership.join!(@board_post, users(:jz))
  end

  test "boards-only filter lists board posts with links to the post page" do
    sign_in :jz

    get work_threads_url(state: "boards", format: :json)
    assert_response :success
    assert_equal [ @board_post.id ], response.parsed_body.fetch("threads").pluck("id")

    get work_threads_url(state: "all", format: :json)
    assert_response :success
    assert_equal [ @board_post.id, @channel_work.id ].sort,
      response.parsed_body.fetch("threads").pluck("id").sort

    get work_threads_url(state: "boards")
    assert_response :success
    assert_select ".work-threads__filter.active", text: "Boards only"
    assert_select ".work-threads__item-link[href='#{room_thread_path(@board, @board_post)}']"
    assert_select ".work-threads__channel", text: "Launch"
  end

  test "channel work rows keep linking to the thread panel" do
    sign_in :jz

    get work_threads_url
    assert_response :success
    assert_select ".work-threads__item-link[href='#{room_path(@room, thread: @channel_work.id)}']"
  end
end
