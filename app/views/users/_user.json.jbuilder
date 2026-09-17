json.cache! user do
  json.(user, :id, :name, :role)

  json.avatar_url fresh_user_avatar_url(user)
  json.icon_name user.icon_name
  json.icon_avatar_url icon_avatar_url(user.icon_name)
end
