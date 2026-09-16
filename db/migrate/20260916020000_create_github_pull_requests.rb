class CreateGithubPullRequests < ActiveRecord::Migration[8.2]
  def change
    create_table :github_pull_requests do |t|
      t.string :owner, null: false
      t.string :repo, null: false
      t.integer :number, null: false
      t.string :title
      t.string :author_login
      t.string :author_avatar_url
      t.string :state
      t.string :base_branch
      t.string :head_branch
      t.string :head_sha
      t.string :review_decision
      t.string :check_status
      t.string :html_url
      t.datetime :github_updated_at
      t.json :payload
      t.datetime :fetched_at
      t.string :fetch_error

      t.timestamps
    end
    add_index :github_pull_requests, %i[ owner repo number ], unique: true, name: "index_github_pull_requests_on_owner_repo_number"

    create_table :github_pull_request_references do |t|
      t.references :message, null: false, foreign_key: true
      t.references :github_pull_request, null: false, foreign_key: true

      t.timestamps
    end
    add_index :github_pull_request_references, %i[ message_id github_pull_request_id ],
      unique: true, name: "index_gh_pr_refs_on_message_and_pr"

    create_table :github_webhook_deliveries do |t|
      t.string :delivery_guid, null: false
      t.string :event

      t.timestamps
    end
    add_index :github_webhook_deliveries, :delivery_guid, unique: true
  end
end
