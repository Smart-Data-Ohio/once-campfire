class Github::DeliverSubscriptionEventJob < ApplicationJob
  def perform(github_event, payload)
    Github::Notifier.deliver(github_event, payload)
  end
end
