class WorkspacePresenceChannel < ApplicationCable::Channel
  def subscribed
    @lease = WorkspacePresenceLease.establish(user: current_user, session: connection.current_session)
    reject unless @lease
  end

  def unsubscribed
    @lease&.delete
  end

  def heartbeat
    return if @lease&.refresh

    @lease = WorkspacePresenceLease.establish(user: current_user, session: connection.current_session)
    reject unless @lease
  end
end
