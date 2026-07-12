# frozen_string_literal: true

# ParaFrame dev loader.
#
# Copy this file into your SketchUp Plugins folder as
# "paraframe_dev_loader.rb" and set PARAFRAME_REPO below to your working
# copy of the repository. SketchUp will then load ParaFrame straight from
# source — no .rbz install needed while developing.
#
#   Windows: %APPDATA%\SketchUp\SketchUp 20xx\SketchUp\Plugins
#   macOS:   ~/Library/Application Support/SketchUp 20xx/SketchUp/Plugins

# --- EDIT THIS PATH (forward slashes work on Windows too) ------------------
PARAFRAME_REPO = 'C:/dev/kopji-window-maker'
# ---------------------------------------------------------------------------

if File.exist?(File.join(PARAFRAME_REPO, 'paraframe.rb'))
  $LOAD_PATH.unshift(PARAFRAME_REPO) unless $LOAD_PATH.include?(PARAFRAME_REPO)
  require 'paraframe.rb'
else
  UI.messagebox(
    "ParaFrame dev loader: repository not found at\n#{PARAFRAME_REPO}\n\n" \
    'Edit PARAFRAME_REPO in paraframe_dev_loader.rb.'
  )
end
