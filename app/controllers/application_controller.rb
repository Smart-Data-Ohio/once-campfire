class ApplicationController < ActionController::Base
  include AllowBrowser, Authentication, Authorization, BlockBannedRequests, SetCurrentRequest, SetPlatform, TrackedRoomVisit, VersionHeaders
  include Turbo::Streams::Broadcasts, Turbo::Streams::StreamName
  include MessagePayloadHelper

  helper MessagePayloadHelper

  private
    def no_store_response!
      response.headers["Cache-Control"] = "no-store"
      response.headers["Pragma"] = "no-cache"
    end
end
