class ChannelThread::PushMessageJob < ApplicationJob
  def perform(thread, message)
    ChannelThread::MessagePusher.new(thread:, message:).push
  end
end
