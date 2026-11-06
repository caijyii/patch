# SPDX-FileCopyrightText: 2026 caijyii
# SPDX-License-Identifier: MIT
import os
import subprocess
app = os.path.abspath(defines['app'])
files = [app]
symlinks = {'Applications': '/Applications'}
format = 'UDZO'
filesystem = 'HFS+'
background = os.path.abspath(defines['background'])
icon = os.path.join(app, 'Contents', 'Resources', 'AppIcon.icns')
window_rect = ((160, 140), (720, 412))
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
default_view = 'icon-view'
include_icon_view_settings = True
include_list_view_settings = False
arrange_by = None
icon_size = 100
text_size = 14
label_pos = 'bottom'
show_icon_preview = False
# Do not set FinderInfo on the signed app; Finder already displays its bundle name.
hide_extensions = []
icon_locations = {'Patch.app': (180, 150), 'Applications': (540, 150)}
grid_spacing = 80

def create_hook(mount_point, options):
    # Verify the copied bundle after all Finder metadata has been applied.
    subprocess.run(
        ['/usr/bin/codesign', '--verify', '--deep', '--strict',
         os.path.join(mount_point, 'Patch.app')], check=True)
