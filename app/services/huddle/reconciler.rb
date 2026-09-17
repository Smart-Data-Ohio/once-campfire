class Huddle::Reconciler
  DEFAULT_INTERVAL = 5.seconds

  def initialize(interval: DEFAULT_INTERVAL)
    @interval = interval
    @stopping = false
  end

  def run
    install_signal_handlers

    until @stopping
      begin
        reconcile_once
      rescue => error
        Rails.logger.error "Huddle reconciliation failed: #{error.class}"
      ensure
        sleep @interval unless @stopping
      end
    end
  end

  # One pass of both loops, extracted so tests can run it without the sleep loop.
  def reconcile_once
    resolve_overdue_invitations
    HuddleCleanup.reconcile_now if Huddle.livekit_admin_configured?
  end

  private
    def resolve_overdue_invitations
      Huddle::InvitationResolver.resolve_overdue!
    rescue => error
      Rails.logger.error "Huddle invitation resolution failed: #{error.class}"
    end

    def install_signal_handlers
      %w[ INT TERM ].each { |signal| Signal.trap(signal) { @stopping = true } }
    end
end
