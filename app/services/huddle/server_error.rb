class Huddle::ServerError < StandardError
  attr_reader :code, :status

  def initialize(status: nil, code: nil)
    @status = status
    @code = code

    super("LiveKit huddle request failed (status=#{status || "unknown"}, code=#{code || "unknown"})")
  end
end
