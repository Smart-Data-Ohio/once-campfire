class Calendar::SyncEntryJob < ApplicationJob
  # Event updates and cancellations enqueue inside transactions; deferring
  # the enqueue to after commit keeps the worker from running on
  # pre-commit state.
  self.enqueue_after_transaction_commit = true

  # Idempotent: the desired state is recomputed from the database at run
  # time. Failures are recorded on the entry for the next change to retry;
  # there is no scheduler here, so this job never waits or retries itself.
  def perform(event_id, user_id)
    Calendar::EntrySync.sync(event_id, user_id)
  end
end
