use scripting additions

on run
    -- The shell script launched this copy and found its process itself, by executable
    -- rather than by whole command line, so there is nothing left to guess at here.
    set targetPID to __PAPERSHELF_PID__
    tell application "__PAPERSHELF_APP_PATH__" to activate

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
                if exists static text "Nothing read yet" of (window (my libraryWindowIndex(targetPID))) then
                    error "Launch opened the empty shelf instead of the catalogue"
                end if
                delay 0.1
            end repeat
        end tell
    end tell
end assertCatalogueLaunchState

-- What one toolbar element says about itself, as {identifier, tooltip}. Handed `a reference
-- to` an index path, never an element: System Events rewrites an element it hands back as
-- `window "<title>"`, and on macOS 27 a window whose title carries a subtitle cannot be found
-- again by that name, so every attribute of a kept element failed to read. `entire contents`
-- returns only such elements, which is how this audit came to find an empty toolbar.
on readControl(element)
    tell application "System Events"
        set identifier to ""
        try
            set identifier to (value of attribute "AXIdentifier" of element) as text
        end try
        set tooltip to ""
        try
            set tooltip to (help of element) as text
        end try
        if tooltip is "missing value" then set tooltip to ""
        return {identifier, tooltip}
    end tell
end readControl

-- Every control in the library window's toolbar, three levels down: an item, the stack a
-- group of buttons is drawn in, and the buttons.
on toolbarControls(targetPID, w)
    set found to {}
    tell application "System Events"
        tell first application process whose unix id is targetPID
            repeat with a from 1 to (count of UI elements of toolbar 1 of window w)
                set end of found to my readControl(a reference to UI element a of toolbar 1 of window w)
                repeat with b from 1 to (count of UI elements of UI element a of toolbar 1 of window w)
                    set end of found to my readControl(a reference to ¬
                        UI element b of UI element a of toolbar 1 of window w)
                    repeat with c from 1 to (count of UI elements of UI element b of ¬
                        UI element a of toolbar 1 of window w)
                        set end of found to my readControl(a reference to ¬
                            UI element c of UI element b of UI element a of toolbar 1 of window w)
                    end repeat
                end repeat
            end repeat
        end tell
    end tell
    return found
end toolbarControls

on auditToolbar(targetPID)
    tell application "System Events"
        tell first application process whose unix id is targetPID
            set w to my libraryWindowIndex(targetPID)
            set labels to description of every button of toolbar 1 of window w
            repeat with label in labels
                set labelText to contents of label as text
                if labelText is "button" or labelText is "" or labelText is "missing value" then
                    error "Unnamed toolbar button"
                end if
            end repeat
            set paletteFound to false
            repeat with found in my toolbarControls(targetPID, w)
                set identifier to item 1 of found
                if identifier starts with "toolbar." then
                    if item 2 of found is "" then
                        error "Toolbar tooltip is missing: " & identifier
                    end if
                    if identifier is "toolbar.commandPalette" then set paletteFound to true
                end if
            end repeat
            -- A narrow window moves toolbar items into the overflow menu, and a tiling window
            -- manager can keep the window narrow whatever size the app asks for. The button is
            -- still in the toolbar then, one click away, so it is looked for there too rather
            -- than failing a run on a machine that tiles its windows.
            set overflowShown to false
            try
                set overflowShown to (description of pop up button 1 of toolbar 1 of window w) ¬
                    is "more toolbar items"
            end try
            if not paletteFound and overflowShown then
                try
                    click pop up button 1 of toolbar 1 of window w
                    delay 0.3
                    if exists (menu item "Open command palette" of menu 1 of ¬
                        pop up button 1 of toolbar 1 of window w) then
                        set paletteFound to true
                    end if
                end try
                key code 53
                delay 0.2
            end if
            if not paletteFound then error "Command palette button is missing from the toolbar"
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

-- The element under this one carrying an identifier, as a reference built from indices, or
-- missing value. Walked rather than taken from `entire contents`, for the reason
-- `readControl` gives.
on elementWithIdentifier(element, wanted, depth)
    tell application "System Events"
        set identifier to ""
        try
            set identifier to (value of attribute "AXIdentifier" of element) as text
        end try
        if identifier is wanted then return element
        if depth > 14 then return missing value
        set childCount to 0
        try
            set childCount to count of UI elements of element
        end try
        repeat with position from 1 to childCount
            set found to my elementWithIdentifier(a reference to UI element position of element, ¬
                wanted, depth + 1)
            if found is not missing value then return found
        end repeat
        return missing value
    end tell
end elementWithIdentifier

-- Sections can move without changing the controls a keyboard or screen reader reaches.
on clickSettingsControl(identifier, targetPID)
    tell application "System Events"
        tell first application process whose unix id is targetPID
            -- Changing the theme rebuilds the settings hierarchy before the next control appears.
            repeat 20 times
                repeat with position from 1 to (count of windows)
                    if (name of window position as text) is "General" then
                        set found to my elementWithIdentifier(a reference to window position, ¬
                            identifier, 0)
                        if found is not missing value then
                            click found
                            return
                        end if
                    end if
                end repeat
                delay 0.1
            end repeat
        end tell
    end tell
    error "Settings control is not exposed: " & identifier
end clickSettingsControl
