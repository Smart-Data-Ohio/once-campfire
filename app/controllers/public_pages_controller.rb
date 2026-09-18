# Public About/Privacy/Terms pages for OAuth verification and workspace
# visitors. Deliberately inherits from ActionController::Base instead of
# ApplicationController: these pages must render without sign-in, without
# setting session cookies, and without the modern-browser gate, and they
# must never touch private workspace state (Current, account, members).
# Framework security defaults (default response headers, forgery
# protection, production force_ssl) still apply; only the app-specific
# before_actions are skipped by not inheriting them.
class PublicPagesController < ActionController::Base
  layout "public"

  before_action :require_html_format

  def about
    @page_title = "Smartfire | About"
  end

  def privacy
    @page_title = "Smartfire | Privacy Policy"
  end

  def terms
    @page_title = "Smartfire | Terms of Service"
  end

  private
    # HTML only: explicit non-HTML formats (e.g. .json) answer 404 so no
    # other representation can leak. A bare wildcard Accept header
    # ("*/*", e.g. curl defaults) still receives the HTML page.
    def require_html_format
      head :not_found unless request.format.html? || request.format.to_s == "*/*"
    end
end
