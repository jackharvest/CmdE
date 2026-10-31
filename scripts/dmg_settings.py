# dmgbuild settings for the CmdE installer DMG.
# create-dmg (Finder AppleScript automation) proved unreliable on this macOS version —
# Finder silently drops "background picture" assignments to icon view options with no
# error (confirmed via raw .DS_Store inspection, see WinDot's STATUS.md for the writeup).
# dmgbuild writes the .DS_Store bytes directly instead of driving a live Finder session,
# sidestepping that regression.
import os

app = defines.get('app', 'CmdE.app')
app_name = os.path.basename(app)

format = 'UDZO'
files = [app]
symlinks = {'Applications': '/Applications'}

volume_name = 'CmdE'
background = defines.get('background', 'dmg_background.png')
icon = defines.get('icon', 'AppIcon.icns')

window_rect = ((200, 200), (660, 400))
icon_size = 128
icon_locations = {
    app_name: (180, 210),
    'Applications': (480, 210),
}
default_view = 'icon-view'
show_icon_preview = False
include_icon_view_settings = True
include_list_view_settings = False
