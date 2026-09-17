# Stream for agent directory and profile live updates. Status changes
# broadcast a Turbo Stream replace of the profile status badge and the
# directory row here. The rendered badge and row carry no credentials or
# grants, so every signed-in human may subscribe. Bots cannot subscribe
# (and cannot open a cable connection at all, which requires a session).
class AgentsChannel < ApplicationCable::Channel
  STREAM_NAME = "agents:all"

  def subscribed
    if current_user && !current_user.bot?
      stream_from STREAM_NAME
    else
      reject
    end
  end
end
