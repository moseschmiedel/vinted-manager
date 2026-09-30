# dmgbuild settings for the "drag to Applications" disk image. Used by make-dmg.sh.
import os

app = defines["app"]
app_name = os.path.basename(app)

format = "ULFO"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = os.path.join(app, "Contents/Resources/AppIcon.icns")

background = os.path.join(defines["settings_dir"], "background.png")  # dmgbuild adds background@2x.png
window_rect = ((200, 120), (660, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 128
text_size = 13
icon_locations = {app_name: (165, 190), "Applications": (495, 190)}
