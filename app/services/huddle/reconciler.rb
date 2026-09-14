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
        HuddleCleanup.reconcile_now if Huddle.livekit_admin_configured?
      rescue => error
        Rails.logger.error "Huddle reconciliation failed: #{error.class}"
      ensure
        sleep @interval unless @stopping
      end
    end
  end

  private
    def install_signal_handlers
      %w[ INT TERM ].each { |signal| Signal.trap(signal) { @stopping = true } }
    end
end
