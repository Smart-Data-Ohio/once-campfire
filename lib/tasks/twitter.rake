# Ad-hoc X post reference backfill for messages that predate the cards
# (or otherwise miss them). Deploys run the same sync through the
# BackfillTwitterPostReferences data migration; this task stays for use
# outside a deploy. Safe to re-run: syncing is idempotent and only
# enqueues fetches for newly referenced posts. See docs/x-posts.md.
namespace :twitter do
  desc "Create X post references for messages containing post URLs"
  task backfill_references: :environment do
    synced = Twitter::PostReferenceBackfill.call

    puts "Backfilled #{synced} #{'message'.pluralize(synced)}"
  end
end
