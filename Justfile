set shell := ["/bin/sh", "-cu"]

# Build the app bundle locally.
build:
    sh scripts/build-app.sh

# Build and replace the installed app in /Applications.
reinstall: build
    osascript -e 'quit app "Ratok"' 2>/dev/null || true
    ditto dist/Ratok.app /Applications/Ratok.app

# Open the locally built app from dist/.
open: build
    open dist/Ratok.app
