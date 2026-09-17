class AddChangedFilesToGithubPullRequests < ActiveRecord::Migration[8.2]
  def change
    add_column :github_pull_requests, :changed_files, :text
    add_column :github_pull_requests, :changed_files_fetched_at, :datetime
  end
end
