# Backfills X post references for messages that predate the cards (or
# otherwise miss them). Legacy messages only gain references when created
# or edited, so untouched ones keep their old OpenGraph boxes until this
# runs. Safe to re-run: syncing is idempotent and only enqueues fetches
# for newly referenced posts. See docs/x-posts.md.
namespace :twitter do
  desc "Create X post references for messages containing post URLs"
  task backfill_references: :environment do
    synced = 0

    Message.includes(:rich_text_body).find_each do |message|
      if Twitter::PostUrl.post_url?(message.markdown_source) || Twitter::PostUrl.post_url?(message.body.to_s)
        Twitter::PostReferenceSync.call(message)
        synced += 1
      end
    end

    puts "Backfilled #{synced} #{'message'.pluralize(synced)}"
  end
end
