class UnfurlLinksController < ApplicationController
  def create
    # PR URLs render as first-class GitHub cards under the message; skip the
    # generic OpenGraph embed so they don't render twice.
    return head(:no_content) if Github::PullRequestUrl.pull_request_url?(url_param)

    opengraph = Opengraph::Metadata.from_url(url_param)

    if opengraph.valid?
      render json: opengraph
    else
      head :no_content
    end
  end

  private
    def url_param
      params.require(:url)
    end
end
