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
            my waitForWindow("All Documents", targetPID)
            my assertCatalogueLaunchState(targetPID)
            my auditToolbar(targetPID)
            my clickSidebarTwice(targetPID)
            tell first application process whose unix id is targetPID to key code 53
        end tell

        tell application "__PAPERSHELF_APP_PATH__" to show settings
        tell application "System Events"
            my waitForWindow("General", targetPID)
            my auditSettings(targetPID)
            tell first application process whose unix id is targetPID to keystroke "w" using command down
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

on assertCatalogueLaunchState(targetPID)
    tell application "System Events"
        tell first application process whose unix id is targetPID
            repeat 50 times
                if exists static text "Ready to run" of (first window whose name starts with "All Documents") then
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
                (first window whose name starts with "All Documents")
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
                (first button of toolbar 1 of (first window whose name starts with "All Documents")) as text
            if sidebarDescription is not "Show Sidebar" and sidebarDescription is not "Hide Sidebar" then
                error "The first toolbar button is not the sidebar toggle"
            end if
            click first button of toolbar 1 of (first window whose name starts with "All Documents")
            delay 0.25
            click first button of toolbar 1 of (first window whose name starts with "All Documents")
        end tell
    end tell
end clickSidebarTwice

on auditSettings(targetPID)
    tell application "System Events"
        tell first application process whose unix id is targetPID
            set controls to buttons of (group 1 of scroll area 1 of group 2 of ¬
                splitter group 1 of group 1 of (first window whose name is "General"))
            if (count of controls) < 6 then
                error "Settings theme and contrast controls are not all exposed"
            end if
            repeat with index from 1 to 3
                click first button of (group 1 of scroll area 1 of group 2 of ¬
                    splitter group 1 of group 1 of (first window whose name is "General")) ¬
                    whose value of attribute "AXIdentifier" is ¬
                    "settings.theme." & (item index of {"system", "light", "dark"})
                delay 0.15
                tell application "__PAPERSHELF_APP_PATH__" to set actualTheme to current theme
                set expectedTheme to item index of {"System", "Light", "Dark"}
                if actualTheme is not expectedTheme then
                    error "Theme button did not apply its value"
                end if
            end repeat
            repeat with index from 1 to 3
                click first button of (group 1 of scroll area 1 of group 2 of ¬
                    splitter group 1 of group 1 of (first window whose name is "General")) ¬
                    whose value of attribute "AXIdentifier" is ¬
                    "settings.pdfContrast." & (item index of {"normal", "tint", "whiteOnBlack"})
                delay 0.15
                tell application "__PAPERSHELF_APP_PATH__" to set actualContrast to current PDF contrast
                set expectedContrast to item index of {"Normal", "Dark tint", "White on black"}
                if actualContrast is not expectedContrast then
                    error "PDF contrast button did not apply its value"
                end if
            end repeat
        end tell
    end tell
end auditSettings
