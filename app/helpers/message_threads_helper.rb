module MessageThreadsHelper
  def thread_panel_data(room)
    {
      room_id: room.id,
      threads_url: room_threads_path(room, format: :json),
      create_url: room_threads_path(room, format: :json),
      channel_name: room_display_name(room, for_user: nil),
      default_avatar_url: asset_path("default-avatar.svg")
    }
  end

  def thread_panel_url(room, thread)
    room_thread_path(room, thread, format: :json)
  end
end
