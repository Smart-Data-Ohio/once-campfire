class WorkspaceIconsController < ApplicationController
  allow_unauthenticated_access only: :show
  before_action :restore_authentication, only: :show

  SVG_CONTENT_TYPE = "image/svg+xml"

  # Uploaded SVGs are validated on save (see WorkspaceIcon), and served with
  # a script-blocking policy so even a missed vector cannot run.
  SVG_SECURITY_HEADERS = {
    "X-Content-Type-Options" => "nosniff",
    "Content-Security-Policy" => "default-src 'none'; style-src 'unsafe-inline'"
  }.freeze

  def show
    icon = WorkspaceIcon.find_by(name: params[:name].to_s.strip.downcase)

    if !signed_in? || icon.nil? || !icon.image.attached?
      head :not_found
    else
      serve_icon icon
    end
  end

  private
    def serve_icon(icon)
      blob = icon.image.blob

      response.headers["Cache-Control"] = "private, max-age=3600"
      response.headers["ETag"] = %("#{blob.checksum}")
      response.headers["X-Content-Type-Options"] = "nosniff"
      response.headers.merge!(SVG_SECURITY_HEADERS) if blob.content_type == SVG_CONTENT_TYPE

      if request.fresh?(response)
        head :not_modified
      else
        send_data blob.download, filename: icon.image.filename.to_s,
          type: blob.content_type, disposition: "inline"
      end
    end
end
