# dmgbuild settings: the app on the left, an Applications link on the right, over the lace background.
import os
app = defines["app"]
bg_dir = defines["bg"]
format = "UDZO"
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
icon_locations = {os.path.basename(app): (180, 190), "Applications": (480, 190)}
background = os.path.join(bg_dir, "background.png")   # dmgbuild picks up background@2x.png beside it
window_rect = ((200, 160), (660, 500))
icon_size = 112
text_size = 13
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
default_view = "icon-view"
