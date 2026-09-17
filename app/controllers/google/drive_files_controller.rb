module Google
  # Viewer-side Drive metadata for message link previews and the composer
  # file picker (JSON only). Resolves with the viewer's own Google
  # credentials at view time; nothing is stored in the database. Every
  # denial answers 404 with an empty body so the endpoint never reveals
  # whether a file exists. Never logs file metadata: error paths carry
  # statuses, never names.
  class DriveFilesController < ApplicationController
    allow_unauthenticated_access only: :index
    before_action :restore_authentication, only: :index

    KINDS_BY_MIME_TYPE = {
      "application/vnd.google-apps.document" => "document",
      "application/vnd.google-apps.spreadsheet" => "spreadsheet",
      "application/vnd.google-apps.presentation" => "presentation",
      "application/vnd.google-apps.form" => "form",
      "application/vnd.google-apps.folder" => "folder",
      "application/pdf" => "pdf"
    }.freeze

    LIST_LIMIT = 30
    LIST_WINDOW = 1.minute

    def show
      account = Current.user.google_account

      unless Google::Client.configured? && Google::DriveLink.valid_id?(params[:id]) &&
          account&.usable? && account.drive?
        return head :not_found
      end

      file = Rails.cache.fetch(cache_key(account, params[:id]), expires_in: 5.minutes) do
        Google::Client.new(account).drive_file(params[:id])
      end

      render json: file_json(file)
    rescue Google::Client::NotFound, Google::Client::Unauthorized
      head :not_found
    rescue Google::Client::Unavailable, Google::Client::Error
      head :service_unavailable
    end

    # Lists the viewer's recent Drive files, or matches by name when q is
    # present. Signed-out visitors 404 here (unlike show's sign-in redirect)
    # so anonymous clients learn nothing about the endpoint.
    def index
      account = Current.user&.google_account

      unless Google::Client.configured? && account&.usable? && account.drive?
        return head :not_found
      end

      if drive_list_throttled?(account.user_id)
        return render json: { error: "rate_limited" }, status: :too_many_requests
      end

      query = params[:q].to_s.strip[0, 100].to_s
      result = Google::Client.new(account).list_drive_files(query: query)

      render json: { files: Array(result["files"]).map { |file| file_json(file) } }
    rescue Google::Client::NotFound, Google::Client::Unauthorized
      head :not_found
    rescue Google::Client::Unavailable, Google::Client::Error
      render json: { error: "drive_unavailable" }, status: :bad_gateway
    end

    private
      def file_json(file)
        {
          id: file["id"],
          name: file["name"],
          kind: KINDS_BY_MIME_TYPE.fetch(file["mimeType"].to_s, "file"),
          modified_at: file["modifiedTime"],
          owner: file["owners"]&.first&.dig("displayName"),
          url: file["webViewLink"]
        }
      end

      # Per-user minute-bucketed counter. Null stores (test env default)
      # answer nil from increment, which counts as unthrottled.
      def drive_list_throttled?(user_id)
        key = "google_drive_list/#{user_id}/#{Time.current.to_i / LIST_WINDOW.to_i}"
        Rails.cache.increment(key, 1, expires_in: LIST_WINDOW).to_i > LIST_LIMIT
      end

      def cache_key(account, file_id)
        "google_drive_file/#{account.user_id}/#{file_id}"
      end
  end
end
