class BackfillTwitterPostReferences < ActiveRecord::Migration[8.2]
  def up
    Twitter::PostReferenceBackfill.call
  end

  def down
    # References are ordinary data; leave the synced rows in place.
  end
end
