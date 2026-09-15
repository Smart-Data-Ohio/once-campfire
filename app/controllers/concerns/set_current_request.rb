module SetCurrentRequest
  extend ActiveSupport::Concern

  included do
    before_action do
      Current.request = request
    end
  end

  def default_url_options
    # A broadcast renderer has its own synthetic request (usually port 80).
    # Override its port explicitly; embedding the real port only in `host`
    # still lets the renderer's separate port option replace it.
    { host: Current.request&.host, port: Current.request&.port, protocol: Current.request_protocol }.compact_blank
  end
end
