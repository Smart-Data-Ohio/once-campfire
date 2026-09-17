module Google
  # Viewer-side Drive metadata for message link previews (JSON only).
  # Resolves with the viewer's own Google credentials at view time; nothing
  # is stored in the database. Every denial answers 404 with an empty body
  # so the endpoint never reveals whether a file exists. Never logs file
  # metadata: error paths carry statuses, never names.
  class DriveFilesController < ApplicationController
    KINDS_BY_MIME_TYPE = {
      "application/vnd.google-apps.document" => "document",
      "application/vnd.google-apps.spreadsheet" => "spreadsheet",
      "application/vnd.google-apps.presentation" => "presentation",
      "application/vnd.google-apps.form" => "form",
      "application/vnd.google-apps.folder" => "folder",
      "application/pdf" => "pdf"
    }.freeze

    def show
      account = Current.user.google_account

      unless Google::Client.configured? && Google::DriveLink.valid_id?(params[:id]) &&
          account&.usable? && account.drive?
        return head :not_found
      end

      file = Rails.cache.fetch(cache_key(account, params[:id]), expires_in: 5.minutes) do
        Google::Client.new(account).drive_file(params[:id])
      end

      render json: {
        id: file["id"],
        name: file["name"],
        kind: KINDS_BY_MIME_TYPE.fetch(file["mimeType"].to_s, "file"),
        modified_at: file["modifiedTime"],
        owner: file["owners"]&.first&.dig("displayName"),
        url: file["webViewLink"]
      }
    rescue Google::Client::NotFound, Google::Client::Unauthorized
      head :not_found
    rescue Google::Client::Unavailable, Google::Client::Error
      head :service_unavailable
    end

    private
      def cache_key(account, file_id)
        "google_drive_file/#{account.user_id}/#{file_id}"
      end
  end
end
