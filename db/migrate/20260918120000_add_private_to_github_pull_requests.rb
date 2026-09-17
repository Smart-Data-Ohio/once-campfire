class AddPrivateToGithubPullRequests < ActiveRecord::Migration[8.2]
  def change
    add_column :github_pull_requests, :private, :boolean
  end
end
