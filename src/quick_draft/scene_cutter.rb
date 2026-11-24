module QuickDraft
  module SceneCutter
    def self.run
      model = Sketchup.active_model
      model.start_operation('Cut Architectural Scenes', true)

      begin
        # TODO: Ask Antigravity to expand automated section planes, tag visibility, and styles
        UI.messagebox('Scene Cutter ready to configure for your studio tags.')
        model.commit_operation
      rescue StandardError => e
        model.abort_operation
        UI.messagebox("Scene Cutter Error: #{e.message}")
      end
    end
  end
end
