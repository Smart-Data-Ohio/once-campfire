module WorkspaceIconTestHelper
  def create_workspace_icon(name: "acme", title: "Acme", file: "clean.svg", creator: users(:david))
    WorkspaceIcon.new(name:, title:, creator:).tap do |icon|
      icon.image.attach(
        io: File.open(Rails.root.join("test/fixtures/files/workspace_icons", file)),
        filename: file
      )
      icon.save!
    end
  end
end
