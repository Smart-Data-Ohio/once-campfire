require "zlib"

module Users::AvatarsHelper
  include IconsAvatarHelper

  AVATAR_COLORS = %w[
    #AF2E1B #CC6324 #3B4B59 #BFA07A #ED8008 #ED3F1C #BF1B1B #736B1E #D07B53
    #736356 #AD1D1D #BF7C2A #C09C6F #698F9C #7C956B #5D618F #3B3633 #67695E
  ]

  def avatar_background_color(user)
    AVATAR_COLORS[Zlib.crc32(user.to_param) % AVATAR_COLORS.size]
  end

  def avatar_tag(user, **options)
    size = options.delete(:size) || 48

    link_to user_path(user), title: user.title, class: "btn avatar", data: { turbo_frame: "_top" } do
      avatar_image_tag user, size: size, aria: { hidden: "true" }, **options
    end
  end

  # A bot with an icon and no uploaded picture shows its icon; an uploaded
  # picture always wins. Everyone else keeps the fresh avatar path. Only
  # class and size apply to the icon; other caller options (loading, aria)
  # are for the <img> fallback.
  def avatar_image_tag(user, size: 48, **options)
    if user.bot? && !user.avatar.attached? && (icon = icon_avatar_tag(user.icon_name, size: size, class: options[:class]))
      icon
    else
      image_tag fresh_user_avatar_path(user), size: size, **options
    end
  end
end
