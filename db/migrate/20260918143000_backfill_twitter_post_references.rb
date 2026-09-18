class BackfillTwitterPostReferences < ActiveRecord::Migration[8.2]
  # Data migration: create references for legacy messages without touching
  # Redis. Migrations run before the job queue is reachable (bin/start-app
  # migrates while redis-server is still starting, and the release rehearsal
  # runs with no network), so fetches are left to the cards themselves: a
  # never-fetched card enqueues its fetch the first time it renders.
  def up
    Twitter::PostReferenceBackfill.call(enqueue_fetches: false)
  end

  def down
    # References are ordinary data; leave the synced rows in place.
  end
end
