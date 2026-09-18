# Background jobs have no request from which to discover the public origin.
# Calendar entries need absolute links back to the event and its meeting room.
require "uri"

if (app_url = ENV["APP_URL"].presence)
  begin
    uri = URI.parse(app_url)
    valid_origin = uri.is_a?(URI::HTTP) && uri.host.present? &&
      uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil? &&
      uri.path.in?([ "", "/" ])
  rescue URI::InvalidURIError
    valid_origin = false
  end

  raise ArgumentError, "APP_URL must be an http or https origin without credentials, a path, query, or fragment" unless valid_origin

  Rails.application.routes.default_url_options.merge!(
    host: uri.host, protocol: uri.scheme, port: uri.port
  )
end
