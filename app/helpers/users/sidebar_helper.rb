module Users::SidebarHelper
  def sidebar_turbo_frame_tag(src: nil, &)
    turbo_frame_tag :user_sidebar, src: src, target: "_top", data: {
      turbo_permanent: true,
      controller: "rooms-list read-rooms turbo-frame",
      rooms_list_unread_class: "unread",
      action: "presence:present@window->rooms-list#read read-rooms:read->rooms-list#read turbo:frame-load->rooms-list#loaded refresh-room:visible@window->turbo-frame#reload".html_safe # otherwise -> is escaped
    }, &
  end

  # In-call huddle participants for all of the current user's rooms, loaded
  # once per render so sidebar rows never query per row. Sidebar stacks take
  # their room's entry as a preloaded `participants:` local; the header stack
  # falls back to HuddleGrant.participants_for when none is given.
  def huddle_participants_by_room_id
    return {} unless Huddle.configured?

    @huddle_participants_by_room_id ||= HuddleGrant.active.in_call
      .where(room_id: Current.user.memberships.select(:room_id))
      .includes(:user)
      .group_by(&:room_id)
      .transform_values { |grants| grants.filter_map(&:user).uniq.sort_by { |user| user.name.downcase } }
  end

  # Two-person DM ids for the current user, counted once: only those DMs can
  # huddle, so only their rows render a stack. One grouped count instead of a
  # COUNT per row.
  def two_person_direct_room_ids
    return [].to_set unless Huddle.configured?

    @two_person_direct_room_ids ||= begin
      direct_room_ids = Current.user.memberships.joins(:room).where(room: { type: "Rooms::Direct" }).select(:room_id)
      Membership.where(room_id: direct_room_ids).group(:room_id).count.select { |_, count| count == 2 }.keys.to_set
    end
  end
end
