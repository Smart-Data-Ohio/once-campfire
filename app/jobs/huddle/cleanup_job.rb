class Huddle::CleanupJob < ApplicationJob
  def perform(cleanup_id)
    HuddleCleanup.find_by(id: cleanup_id)&.perform_from_queue!
  end
end
