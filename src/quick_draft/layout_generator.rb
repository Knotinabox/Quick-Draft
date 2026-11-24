module QuickDraft
  module LayoutGenerator
    def self.run
      model = Sketchup.active_model
      if model.path.empty?
        UI.messagebox('Please save your SketchUp model before generating LayOut sheets.')
        return
      end

      # TODO: Ask Antigravity to expand viewport placement, architectural scales, and PDF export
      UI.messagebox("Ready to send #{model.pages.count} scenes from #{File.basename(model.path)} to LayOut.")
    end
  end
end
