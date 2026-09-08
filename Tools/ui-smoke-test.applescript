use scripting additions

on run
    tell application "__PAPERSHELF_APP_PATH__" to activate
    set targetPID to my waitForProcess("__PAPERSHELF_EXECUTABLE__")

    tell application "__PAPERSHELF_APP_PATH__"
        set savedTheme to current theme
        set savedContrast to current PDF contrast
    end tell

    try
        tell application "__PAPERSHELF_APP_PATH__"
            choose theme "dark"
            choose theme "light"
            choose theme savedTheme
            choose PDF contrast "white on black"
            choose PDF contrast "dark tint"
            choose PDF contrast "sepia"
            choose PDF contrast savedContrast
            show catalogue
            show notes
            toggle inspector
            toggle inspector
            toggle reading mode
            toggle reading mode
            copy current citation
            bookmark current page
            remove current bookmark
            show bookmarks
            open command palette
        end tell

        tell application "System Events"
            my waitForLibraryWindow(targetPID)
            -- Before the audits, not after. The last command above opens the palette, and its
            -- sheet is what made a toolbar lookup resolve somewhere unintended.
            tell first application process whose unix id is targetPID to key code 53
            delay 0.3
            my assertCatalogueLaunchState(targetPID)
            my auditToolbar(targetPID)
            my clickSidebarTwice(targetPID)
        end tell

        tell application "__PAPERSHELF_APP_PATH__" to show settings
        tell application "System Events"
            my waitForWindow("General", targetPID)
            my auditSettings(targetPID)
            -- Guarded: an unconditional close here shut the library window on any run where
            -- settings never opened, which left the app running with nothing on screen.
            tell first application process whose unix id is targetPID
                if (exists (first window whose name is "General")) then
                    keystroke "w" using command down
                end if
            end tell
        end tell
    on error messageText number errorNumber
        tell application "__PAPERSHELF_APP_PATH__"
            choose theme savedTheme
            choose PDF contrast savedContrast
        end tell
        error messageText number errorNumber
    end try

    tell application "__PAPERSHELF_APP_PATH__"
        choose theme savedTheme
        choose PDF contrast savedContrast
    end tell
    return "PaperShelf UI smoke test passed"
end run

on waitForProcess(executablePath)
    repeat 50 times
        try
            set processID to do shell script "/usr/bin/pgrep -n -f -x " & quoted form of executablePath
            if processID is not "" then return processID as integer
        end try
        delay 0.1
    end repeat
    error "Timed out waiting for PaperShelf at " & executablePath
end waitForProcess

on waitForWindow(prefix, targetPID)
    tell application "System Events"
        tell first application process whose unix id is targetPID
            repeat 120 times
                repeat with candidate in windows
                    if (name of contents of candidate as text) starts with prefix then return
                end repeat
                delay 0.1
            end repeat
        end tell
    end tell
    error "Timed out waiting for a PaperShelf window named " & prefix
end waitForWindow

-- The library window, found by the one thing that distinguishes it rather than by its title.
--
-- It used to be found by title, on the assumption that the shelf names it. The window is named
-- after whatever it is showing: `placeTitle` answers with the open document's own title
-- whenever there is one, so an app that restored into a paper produced no window called "All
-- Documents" and every wait here ran to its timeout. There is no command to close a reader, so
-- the title cannot be forced either.
--
-- Not `window 1` either, which is what this reached for first and which wedged the app: with
-- the command palette open its sheet can be the first window, and a toolbar lookup against it
-- resolves somewhere unintended. A click then landed on the page instead of the toolbar, which
-- puts PDFKit into `trackStandardTextSelection`, a modal loop that runs until a mouse-up that
-- a synthetic click never sends. The main thread blocks, every later AppleEvent times out, and
-- the app has to be killed.
--
-- The library window is the one carrying a toolbar, which no sheet and no reader window does.
--
-- Its INDEX, not a reference to it. A window reference resolves by name at the moment it is
-- used, and this script toggles reading mode, which renames the window after the reference
-- was taken. An index survives that; a reference goes stale and the lookup fails naming a
-- title that was true a moment ago.
on libraryWindowIndex(targetPID)
    tell application "System Events"
        tell first application process whose unix id is targetPID
            repeat with position from 1 to (count of windows)
                if (exists toolbar 1 of window position) then return position
            end repeat
        end tell
    end tell
    error "PaperShelf has no window with a toolbar"
end libraryWindowIndex

on waitForLibraryWindow(targetPID)
    repeat 120 times
        try
            return my libraryWindowIndex(targetPID)
        on error
            delay 0.1
        end try
    end repeat
    error "Timed out waiting for the PaperShelf library window"
end waitForLibraryWindow

on assertCatalogueLaunchState(targetPID)
    tell application "System Events"
        tell first application process whose unix id is targetPID
            repeat 50 times
                if exists static text "Ready to run" of (window (my libraryWindowIndex(targetPID))) then
                    error "Launch opened the rename prompt instead of the catalogue"
                end if
                delay 0.1
            end repeat
        end tell
    end tell
end assertCatalogueLaunchState

on auditToolbar(targetPID)
    tell application "System Events"
        tell first application process whose unix id is targetPID
            set labels to description of every button of toolbar 1 of ¬
                (window (my libraryWindowIndex(targetPID)))
            repeat with label in labels
                set labelText to contents of label as text
                if labelText is "button" or labelText is "" or labelText is "missing value" then
                    error "Unnamed toolbar button"
                end if
            end repeat
        end tell
    end tell
end auditToolbar

on clickSidebarTwice(targetPID)
    tell application "System Events"
        tell first application process whose unix id is targetPID
            set sidebarDescription to description of ¬
                (first button of toolbar 1 of (window (my libraryWindowIndex(targetPID)))) as text
            if sidebarDescription is not "Show Sidebar" and sidebarDescription is not "Hide Sidebar" then
                error "The first toolbar button is not the sidebar toggle"
            end if
            click first button of toolbar 1 of (window (my libraryWindowIndex(targetPID)))
            delay 0.25
            click first button of toolbar 1 of (window (my libraryWindowIndex(targetPID)))
        end tell
    end tell
end clickSidebarTwice

on auditSettings(targetPID)
    tell application "System Events"
        tell first application process whose unix id is targetPID
            repeat with index from 1 to 3
                my clickSettingsControl("settings.theme." & ¬
                    (item index of {"system", "light", "dark"}), targetPID)
                delay 0.15
                tell application "__PAPERSHELF_APP_PATH__" to set actualTheme to current theme
                set expectedTheme to item index of {"System", "Light", "Dark"}
                if actualTheme is not expectedTheme then
                    error "Theme button did not apply its value"
                end if
            end repeat
            repeat with index from 1 to 4
                my clickSettingsControl("settings.pdfContrast." & ¬
                    (item index of {"normal", "sepia", "tint", "whiteOnBlack"}), targetPID)
                delay 0.15
                tell application "__PAPERSHELF_APP_PATH__" to set actualContrast to current PDF contrast
                set expectedContrast to ¬
                    item index of {"Normal", "Sepia", "Dark tint", "White on black"}
                if actualContrast is not expectedContrast then
                    error "PDF contrast button did not apply its value"
                end if
            end repeat
        end tell
    end tell
end auditSettings

-- Sections can move without changing the controls a keyboard or screen reader reaches.
on clickSettingsControl(identifier, targetPID)
    tell application "System Events"
        tell first application process whose unix id is targetPID
            set controls to entire contents of (first window whose name is "General")
            repeat with candidateControl in controls
                set controlIdentifier to ""
                try
                    set controlIdentifier to value of attribute "AXIdentifier" of candidateControl
                end try
                if controlIdentifier is identifier then
                    click candidateControl
                    return
                end if
            end repeat
        end tell
    end tell
    error "Settings control is not exposed: " & identifier
end clickSettingsControl
